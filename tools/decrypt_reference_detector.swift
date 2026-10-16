// Diagnostic for the user-owned, installed Foresight detector only.
// Reads one exact model key without interaction; never prints or stores key material.
// Writes authenticated model bytes to a new private file; does not modify the app.
// Tink wire schemas: https://github.com/tink-crypto/tink/tree/master/proto
import Foundation
import Security
import LocalAuthentication
import CryptoKit
import Darwin

enum Failure: Error { case invalid(String) }
struct Field { let number: Int; let integer: UInt64?; let bytes: Data? }
func fields(_ input: Data) throws -> [Field] {
 let data = [UInt8](input); var offset = 0; var result = [Field]()
 func varint() throws -> UInt64 {
  var value: UInt64 = 0
  for shift in stride(from: 0, through: 63, by: 7) {
   guard offset < data.count else { throw Failure.invalid("Truncated protobuf") }
   let byte = data[offset]; offset += 1
   guard shift != 63 || byte < 2 else { throw Failure.invalid("Protobuf overflow") }
   value |= UInt64(byte & 127) << shift
   if byte < 128 { return value }
  }
  throw Failure.invalid("Invalid protobuf")
 }
 while offset < data.count {
  let tag = try varint(); let number = Int(tag >> 3)
  guard number > 0 else { throw Failure.invalid("Invalid field") }
  switch tag & 7 {
  case 0: result.append(Field(number: number, integer: try varint(), bytes: nil))
  case 2:
   let size = try varint()
   guard size <= UInt64(data.count - offset) else { throw Failure.invalid("Truncated field") }
   result.append(Field(number: number, integer: nil, bytes: Data(data[offset..<(offset+Int(size))])))
   offset += Int(size)
  case 1, 5:
   let size = tag & 7 == 1 ? 8 : 4
   guard size <= data.count-offset else { throw Failure.invalid("Truncated scalar") }
   offset += size
  default: throw Failure.invalid("Unsupported wire type")
  }
 }
 return result
}
func integer(_ values: [Field], _ n: Int) -> UInt64 { values.last(where: {$0.number == n})?.integer ?? 0 }
func bytes(_ values: [Field], _ n: Int) throws -> Data {
 guard let data = values.last(where: {$0.number == n})?.bytes else { throw Failure.invalid("Missing required field") }
 return data
}
func decrypt(_ encrypted: Data, keyset: Data) throws -> Data {
 guard encrypted.count > 33, encrypted.first == 1 else { throw Failure.invalid("Expected Tink ciphertext") }
 let keyID = encrypted.dropFirst().prefix(4).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
 let set = try fields(keyset)
 for entry in set where entry.number == 2 {
  guard let data = entry.bytes else { continue }
  let key = try fields(data)
  guard integer(key,2) == 1, integer(key,3) == keyID, integer(key,4) == 1 else { continue }
  let kd = try fields(bytes(key,1))
  guard String(data: try bytes(kd,1), encoding:.utf8) == "type.googleapis.com/google.crypto.tink.AesGcmKey", integer(kd,3) == 1 else { continue }
  let aes = try fields(bytes(kd,2)); let material = try bytes(aes,3)
  guard integer(aes,1) == 0, material.count == 32 else { throw Failure.invalid("Unsupported AES key") }
  let payload = Data(encrypted.dropFirst(5))
  let box = try AES.GCM.SealedBox(combined: payload)
  return try AES.GCM.open(box, using: SymmetricKey(data: material), authenticating: Data())
 }
 throw Failure.invalid("No matching model encryption key")
}
func encodeVarint(_ value: UInt64) -> Data {
 var x=value; var result=Data()
 repeat { var b=UInt8(x & 127);x >>= 7;if x > 0 {b |= 128};result.append(b) } while x > 0
 return result
}
func scalar(_ n:UInt64,_ value:UInt64)->Data { encodeVarint(n << 3)+encodeVarint(value) }
func blob(_ n:UInt64,_ value:Data)->Data { encodeVarint(n << 3 | 2)+encodeVarint(UInt64(value.count))+value }
func selfTest() throws {
 let key=SymmetricKey(size:.bits256);let material=key.withUnsafeBytes {Data($0)}
 let aes=blob(3,material)
 let kd=blob(1,Data("type.googleapis.com/google.crypto.tink.AesGcmKey".utf8))+blob(2,aes)+scalar(3,1)
 let entry=blob(1,kd)+scalar(2,1)+scalar(3,7)+scalar(4,1)
 let keyset=scalar(1,7)+blob(2,entry)
 let original=Data("controlled detector format test".utf8)
 let sealed=try AES.GCM.seal(original,using:key,authenticating:Data())
 let encrypted=Data([1,0,0,0,7])+sealed.combined!
 guard try decrypt(encrypted,keyset:keyset) == original else {throw Failure.invalid("Self-test mismatch")}
 var damaged=encrypted;damaged[damaged.count-1] ^= 1
 do { _ = try decrypt(damaged,keyset:keyset);throw Failure.invalid("Authentication accepted corruption") }
 catch is CryptoKitError { }
 print("Controlled AES-GCM/keyset test passed; corruption rejected")
}
do {
 if CommandLine.arguments == [CommandLine.arguments[0],"--self-test"] {try selfTest();exit(0)}
 guard CommandLine.arguments.count == 2 else {throw Failure.invalid("Expected new output path or --self-test")}
 let output=CommandLine.arguments[1]
 guard !FileManager.default.fileExists(atPath:output) else {throw Failure.invalid("Output must not exist")}
 let context=LAContext();context.interactionNotAllowed=true
 let query:[CFString:Any]=[kSecClass:kSecClassGenericPassword,kSecAttrService:"com.google.AIEdgeForesight.encryption",kSecAttrAccount:"dataEncryptionKey",kSecMatchLimit:kSecMatchLimitOne,kSecReturnData:true,kSecUseAuthenticationContext:context]
 var item:CFTypeRef?
 let status=SecItemCopyMatching(query as CFDictionary,&item)
 guard status == errSecSuccess, let keyset=item as? Data else {throw Failure.invalid("Exact model-key read status \(status)")}
 let source=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.google.AIEdgeForesight/models/4/1.1/f450f245265502c7760774e.tflite")
 let plaintext=try decrypt(Data(contentsOf:source),keyset:keyset)
 guard plaintext.count >= 8, plaintext.subdata(in:4..<8) == Data("TFL3".utf8) else {throw Failure.invalid("Decrypted output lacks TFLite identifier")}
 let fd=open(output,O_WRONLY|O_CREAT|O_EXCL,0o600)
 guard fd >= 0 else {throw Failure.invalid("Could not create private output")}
 let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
 try handle.write(contentsOf:plaintext);try handle.close()
 print("Authenticated detector model: \(plaintext.count) bytes; TFL3 verified")
 print("SHA256 \(SHA256.hash(data:plaintext).map{String(format:"%02x",$0)}.joined())")
} catch {
 // Errors contain status/format descriptions only; no key or protobuf bytes.
 print("Detector diagnostic failed: \(error)")
 exit(1)
}
