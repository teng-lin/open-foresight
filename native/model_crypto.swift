import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

private let keychainService = "com.openforesight.encryption"
private let keychainAccount = "dataEncryptionKey"
private let aesGcmType = "type.googleapis.com/google.crypto.tink.AesGcmKey"

private enum ModelCryptoError: Error, CustomStringConvertible {
    case invalidKeyset
    case invalidCiphertext
    case missingKey
    case keychain(OSStatus)
    case random(OSStatus)
    case outputExists
    case file(String, Int32)
    case usage
    case selfTest

    var description: String {
        switch self {
        case .invalidKeyset: return "Invalid local model encryption keyset"
        case .invalidCiphertext: return "Invalid or unauthenticated encrypted model"
        case .missingKey: return "Local model encryption key is unavailable"
        case .keychain(let status): return "Local model key storage failed (\(status))"
        case .random(let status): return "Secure random generation failed (\(status))"
        case .outputExists: return "Model output already exists"
        case .file(let operation, let code): return "Model file \(operation) failed (\(code))"
        case .usage: return "Usage: model-crypto encrypt|decrypt --input SOURCE --output DEST, or --self-test"
        case .selfTest: return "Model crypto self-test failed"
        }
    }
}

private enum ProtoValue {
    case number(UInt64)
    case bytes(Data)
}

private struct ProtoMessage {
    let fields: [UInt32: [ProtoValue]]

    init(_ data: Data) throws {
        guard data.count <= 65_536 else { throw ModelCryptoError.invalidKeyset }
        let bytes = [UInt8](data)
        var cursor = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            for index in 0..<10 {
                guard cursor < bytes.count else { throw ModelCryptoError.invalidKeyset }
                let byte = bytes[cursor]
                cursor += 1
                if index == 9 && byte > 1 { throw ModelCryptoError.invalidKeyset }
                result |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return result }
            }
            throw ModelCryptoError.invalidKeyset
        }
        var parsed: [UInt32: [ProtoValue]] = [:]
        var fieldCount = 0
        while cursor < bytes.count {
            fieldCount += 1
            guard fieldCount <= 256 else { throw ModelCryptoError.invalidKeyset }
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 0x1fffffff else {
                throw ModelCryptoError.invalidKeyset
            }
            let field = UInt32(tag >> 3)
            switch tag & 7 {
            case 0:
                parsed[field, default: []].append(.number(try varint()))
            case 2:
                let length = try varint()
                guard length <= UInt64(bytes.count - cursor) else {
                    throw ModelCryptoError.invalidKeyset
                }
                let end = cursor + Int(length)
                parsed[field, default: []].append(.bytes(Data(bytes[cursor..<end])))
                cursor = end
            case 1, 5:
                let count = tag & 7 == 1 ? 8 : 4
                guard count <= bytes.count - cursor else { throw ModelCryptoError.invalidKeyset }
                cursor += count
            default:
                throw ModelCryptoError.invalidKeyset
            }
        }
        fields = parsed
    }

    func number(_ field: UInt32, default fallback: UInt64? = nil) throws -> UInt64 {
        guard let values = fields[field] else {
            if let fallback = fallback { return fallback }
            throw ModelCryptoError.invalidKeyset
        }
        guard values.count == 1, case .number(let value) = values[0] else {
            throw ModelCryptoError.invalidKeyset
        }
        return value
    }

    func bytes(_ field: UInt32) throws -> Data {
        guard let values = fields[field], values.count == 1,
              case .bytes(let value) = values[0] else { throw ModelCryptoError.invalidKeyset }
        return value
    }
}

private func varint(_ value: UInt64) -> Data {
    var remaining = value
    var bytes: [UInt8] = []
    repeat {
        let byte = UInt8(remaining & 127)
        remaining >>= 7
        bytes.append(remaining == 0 ? byte : byte | 128)
    } while remaining != 0
    return Data(bytes)
}

private func scalar(_ field: UInt64, _ value: UInt64) -> Data {
    varint(field << 3) + varint(value)
}

private func blob(_ field: UInt64, _ value: Data) -> Data {
    varint(field << 3 | 2) + varint(UInt64(value.count)) + value
}

private func randomBytes(_ count: Int) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = bytes.withUnsafeMutableBytes {
        SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
    }
    guard status == errSecSuccess else { throw ModelCryptoError.random(status) }
    return Data(bytes)
}

private struct ModelKeyset {
    let serialized: Data
    let primaryID: UInt32
    let keys: [UInt32: SymmetricKey]

    init(_ data: Data) throws {
        let keyset = try ProtoMessage(data)
        let primary = try keyset.number(1)
        guard primary > 0, primary <= UInt64(UInt32.max),
              let entries = keyset.fields[2], !entries.isEmpty, entries.count <= 64 else {
            throw ModelCryptoError.invalidKeyset
        }
        var usable: [UInt32: SymmetricKey] = [:]
        var identifiers = Set<UInt32>()
        for entry in entries {
            guard case .bytes(let data) = entry else { throw ModelCryptoError.invalidKeyset }
            let key = try ProtoMessage(data)
            let rawID = try key.number(3)
            guard rawID > 0, rawID <= UInt64(UInt32.max),
                  identifiers.insert(UInt32(rawID)).inserted else {
                throw ModelCryptoError.invalidKeyset
            }
            // Disabled/retired entries may remain in a rotated Tink keyset.
            guard try key.number(2) == 1 else { continue }
            guard try key.number(4) == 1 else { continue }
            let keyData = try ProtoMessage(key.bytes(1))
            guard try keyData.bytes(1) == Data(aesGcmType.utf8),
                  try keyData.number(3) == 1 else { throw ModelCryptoError.invalidKeyset }
            let aes = try ProtoMessage(keyData.bytes(2))
            guard try aes.number(1, default: 0) == 0 else { throw ModelCryptoError.invalidKeyset }
            let secret = try aes.bytes(3)
            guard secret.count == 32 else { throw ModelCryptoError.invalidKeyset }
            usable[UInt32(rawID)] = SymmetricKey(data: secret)
        }
        guard usable[UInt32(primary)] != nil else { throw ModelCryptoError.invalidKeyset }
        serialized = data
        primaryID = UInt32(primary)
        keys = usable
    }

    static func generate() throws -> ModelKeyset {
        var identifier: UInt32 = 0
        while identifier == 0 {
            identifier = try randomBytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } & 0x7fffffff
        }
        let aes = blob(3, try randomBytes(32)) // version 0 is the protobuf default.
        let keyData = blob(1, Data(aesGcmType.utf8)) + blob(2, aes) + scalar(3, 1)
        let key = blob(1, keyData) + scalar(2, 1) + scalar(3, UInt64(identifier)) + scalar(4, 1)
        return try ModelKeyset(scalar(1, UInt64(identifier)) + blob(2, key))
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        guard let key = keys[primaryID] else { throw ModelCryptoError.invalidKeyset }
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw ModelCryptoError.invalidCiphertext }
        let id = primaryID
        return Data([1, UInt8((id >> 24) & 255), UInt8((id >> 16) & 255),
                     UInt8((id >> 8) & 255), UInt8(id & 255)]) + combined
    }

    func decrypt(_ encrypted: Data) throws -> Data {
        // Empty plaintext is valid: 5-byte Tink prefix + 12-byte nonce + 16-byte tag.
        guard encrypted.count >= 33, encrypted.first == 1 else {
            throw ModelCryptoError.invalidCiphertext
        }
        let id = encrypted.dropFirst().prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard let key = keys[id] else { throw ModelCryptoError.invalidCiphertext }
        do {
            let box = try AES.GCM.SealedBox(combined: Data(encrypted.dropFirst(5)))
            return try AES.GCM.open(box, using: key) // Empty associated data.
        } catch {
            throw ModelCryptoError.invalidCiphertext
        }
    }
}

private func storedKeyset(create: Bool) throws -> ModelKeyset {
    // This helper never queries the original application's Keychain service.
    let identity: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: keychainService,
        kSecAttrAccount as String: keychainAccount,
    ]
    var query = identity
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let context = LAContext()
    context.interactionNotAllowed = true
    query[kSecUseAuthenticationContext as String] = context
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess {
        guard let data = result as? Data else { throw ModelCryptoError.invalidKeyset }
        return try ModelKeyset(data)
    }
    guard status == errSecItemNotFound else { throw ModelCryptoError.keychain(status) }
    guard create else { throw ModelCryptoError.missingKey }
    let generated = try ModelKeyset.generate()
    var item = identity
    item[kSecValueData as String] = generated.serialized
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let inserted = SecItemAdd(item as CFDictionary, nil)
    // Concurrent first use must retain the winning key, never replace it.
    if inserted == errSecDuplicateItem { return try storedKeyset(create: false) }
    guard inserted == errSecSuccess else { throw ModelCryptoError.keychain(inserted) }
    return generated
}

private func writeExclusive(_ data: Data, to path: String) throws {
    let output = URL(fileURLWithPath: path).standardizedFileURL
    let temporary = output.deletingLastPathComponent()
        .appendingPathComponent(".foresight-model-crypto-\(UUID().uuidString).tmp").path
    let descriptor = Darwin.open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw ModelCryptoError.file("create", errno) }
    var open = true
    defer {
        if open { Darwin.close(descriptor) }
        Darwin.unlink(temporary)
    }
    guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else {
        throw ModelCryptoError.file("permissions", errno)
    }
    try data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw ModelCryptoError.file("write", errno) }
            offset += count
        }
    }
    guard Darwin.fsync(descriptor) == 0 else { throw ModelCryptoError.file("sync", errno) }
    let closeResult = Darwin.close(descriptor)
    open = false
    guard closeResult == 0 else { throw ModelCryptoError.file("close", errno) }
    // A same-directory hard link atomically publishes the completed inode and
    // refuses an existing destination, including symlinks. Never rename over it.
    guard Darwin.link(temporary, output.path) == 0 else {
        if errno == EEXIST { throw ModelCryptoError.outputExists }
        throw ModelCryptoError.file("publish", errno)
    }
}

private func selfTest() throws {
    // Fixed public Tink wire fixture, independent of scalar()/blob(): key ID 7,
    // ENABLED, TINK prefix, AES256GCM, 32 zero key bytes, omitted version 0.
    let fixedKeyset = Data([0x08, 0x07, 0x12, 0x60, 0x0a, 0x58, 0x0a, 0x30])
        + Data("type.googleapis.com/google.crypto.tink.AesGcmKey".utf8)
        + Data([0x12, 0x22, 0x1a, 0x20]) + Data(repeating: 0, count: 32)
        + Data([0x18, 0x01, 0x10, 0x01, 0x18, 0x07, 0x20, 0x01])
    // AES-256-GCM: zero key, zero 96-bit nonce, empty plaintext and AAD.
    let fixedCiphertext = Data([1, 0, 0, 0, 7]) + Data(repeating: 0, count: 12)
        + Data([0x53, 0x0f, 0x8a, 0xfb, 0xc7, 0x45, 0x36, 0xb9,
                0xa9, 0x63, 0xb4, 0xf1, 0xc4, 0xcb, 0x73, 0x8b])
    guard try ModelKeyset(fixedKeyset).decrypt(fixedCiphertext).isEmpty else {
        throw ModelCryptoError.selfTest
    }
    let generated = try ModelKeyset.generate()
    let parsed = try ModelKeyset(generated.serialized)
    for plaintext in [Data(), Data("ephemeral model crypto round trip".utf8)] {
        let encrypted = try parsed.encrypt(plaintext)
        guard encrypted.count == plaintext.count + 33,
              try parsed.decrypt(encrypted) == plaintext else { throw ModelCryptoError.selfTest }
        var tampered = encrypted
        tampered[tampered.count - 1] ^= 1
        do {
            _ = try parsed.decrypt(tampered)
            throw ModelCryptoError.selfTest
        } catch ModelCryptoError.invalidCiphertext { }
    }
    do {
        _ = try ProtoMessage(Data(repeating: 255, count: 11))
        throw ModelCryptoError.selfTest
    } catch ModelCryptoError.invalidKeyset { }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("foresight-model-crypto-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("model.bin").path
    let plaintext = Data("ephemeral model file".utf8)
    try writeExclusive(plaintext, to: output)
    var metadata = stat()
    guard Darwin.lstat(output, &metadata) == 0,
          metadata.st_mode & 0o777 == 0o600, metadata.st_uid == getuid(),
          try Data(contentsOf: URL(fileURLWithPath: output)) == plaintext else {
        throw ModelCryptoError.selfTest
    }
    do {
        try writeExclusive(Data("must not replace".utf8), to: output)
        throw ModelCryptoError.selfTest
    } catch ModelCryptoError.outputExists { }
    let symlink = directory.appendingPathComponent("model-link.bin").path
    try FileManager.default.createSymbolicLink(atPath: symlink, withDestinationPath: output)
    do {
        try writeExclusive(Data("must not follow".utf8), to: symlink)
        throw ModelCryptoError.selfTest
    } catch ModelCryptoError.outputExists { }
    guard try Data(contentsOf: URL(fileURLWithPath: output)) == plaintext,
          try FileManager.default.destinationOfSymbolicLink(atPath: symlink) == output,
          try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
              == ["model-link.bin", "model.bin"] else { throw ModelCryptoError.selfTest }
    print("Model crypto self-test passed.")
}

private func main() -> Int32 {
    do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--self-test"] {
            try selfTest() // Deliberately no Keychain calls on this path.
            return 0
        }
        guard arguments.count == 5, arguments[0] == "encrypt" || arguments[0] == "decrypt" else {
            throw ModelCryptoError.usage
        }
        var paths: [String: String] = [:]
        for index in stride(from: 1, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard ["--input", "--output"].contains(flag), paths[flag] == nil else {
                throw ModelCryptoError.usage
            }
            paths[flag] = arguments[index + 1]
        }
        guard let source = paths["--input"], let destination = paths["--output"] else {
            throw ModelCryptoError.usage
        }
        var existing = stat()
        if Darwin.lstat(destination, &existing) == 0 { throw ModelCryptoError.outputExists }
        guard errno == ENOENT else { throw ModelCryptoError.file("output check", errno) }
        let input = try Data(contentsOf: URL(fileURLWithPath: source), options: .mappedIfSafe)
        let encrypting = arguments[0] == "encrypt"
        let keyset = try storedKeyset(create: encrypting)
        let result = try encrypting ? keyset.encrypt(input) : keyset.decrypt(input)
        try writeExclusive(result, to: destination)
        print(encrypting ? "Model encrypted." : "Model decrypted.")
        return 0
    } catch let error as ModelCryptoError {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 1
    } catch {
        // Foundation/CryptoKit errors must not expose input or key contents.
        FileHandle.standardError.write(Data("Model cryptographic operation failed\n".utf8))
        return 1
    }
}

exit(main())
