import Foundation
import AppKit
import PDFKit
import Darwin

// Apply the deny policy before invoking parsers on untrusted bytes. Framework
// code may load system resources; user files and all networking remain denied.
@_silgen_name("sandbox_init")
func applySandbox(_ profile: UnsafePointer<CChar>, _ flags: UInt64,
                  _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
@_silgen_name("sandbox_free_error")
func freeSandboxError(_ error: UnsafeMutablePointer<CChar>)

func confineParser() throws {
    let profile = """
    (version 1)
    (deny default)
    (allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/Library/Fonts"))
    (allow sysctl-read)
    (allow signal (target self))
    (allow mach-lookup (global-name "com.apple.FontObjectsServer") (global-name "com.apple.system.logger"))
    """
    var error: UnsafeMutablePointer<CChar>?
    let status = profile.withCString { applySandbox($0, 0, &error) }
    if status != 0 {
        let message = error.map { String(cString: $0) } ?? "unknown sandbox error"
        if let error = error { freeSandboxError(error) }
        throw fail("Cannot confine document parser: \(message)")
    }
}

// Service-owned extraction: no windows, shell commands, or permission prompts.
// File access is explicitly requested by the caller's import operation.
struct ExtractionFailure: Error {
    let message: String
    let code: Int32
}

func fail(_ message: String, _ code: Int32 = 1) -> ExtractionFailure {
    ExtractionFailure(message: message, code: code)
}

func extract(_ kind: String, _ path: String) throws -> String {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else {
        throw fail("Cannot open the selected document safely. Check Files and Folders access in System Settings, or choose a readable copy.")
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0,
          (metadata.st_mode & S_IFMT) == S_IFREG,
          metadata.st_size >= 0 && metadata.st_size <= 10 * 1024 * 1024 else {
        close(descriptor)
        throw fail("The selected document must be a regular file of at most 10 MiB.")
    }
    let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let data: Data
    do {
        data = try input.readToEnd() ?? Data()
        try input.close()
    } catch {
        throw fail("Cannot read the selected document: \(error.localizedDescription)")
    }
    // The selected input is now an immutable buffer; the parser receives no
    // readable user file descriptors and cannot open another user document.
    try confineParser()
    let text: String
    if kind == "--pdf" {
        guard let document = PDFDocument(data: data) else {
            throw fail("The selected file is not a readable PDF.")
        }
        guard !document.isLocked else {
            throw fail("This PDF is password protected. Import an unlocked copy.", 4)
        }
        guard document.pageCount > 0 else { throw fail("The PDF contains no pages.", 3) }
        text = document.string ?? ""
    } else {
        // AppKit can accept other formats permissively. Reject accidental plain
        // text rather than recording it as a successfully parsed RTF document.
        let header = String(decoding: data.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard header.hasPrefix("{\\rtf") else { throw fail("The selected file is not a valid RTF document.") }
        do {
            text = try NSAttributedString(data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil).string
        } catch { throw fail("RTF extraction failed: \(error.localizedDescription)") }
    }
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw fail(kind == "--pdf"
            ? "No selectable text was found in this PDF. Scanned images require OCR; import a text-based copy."
            : "The RTF document contains no text.", 3)
    }
    return text
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2 && arguments[0] == "--sandbox-probe" {
    do {
        try confineParser()
        let file = open(arguments[1], O_RDONLY)
        if file >= 0 { close(file) }
        let connection = socket(AF_INET, SOCK_STREAM, 0)
        var denied = connection < 0
        if connection >= 0 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(9).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(connection, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            denied = result < 0 && (errno == EPERM || errno == EACCES)
            close(connection)
        }
        guard file < 0 && denied else { throw fail("Parser sandbox did not deny file and network access.") }
        print("{\"file_denied\":true,\"network_denied\":true}")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Parser sandbox probe failed: \(error)\n".utf8))
        exit(1)
    }
}
guard arguments.count == 2, ["--pdf", "--rtf"].contains(arguments[0]) else {
    FileHandle.standardError.write(Data("Usage: foresight-file-parser --pdf PATH | --rtf PATH\n".utf8))
    exit(2)
}
do {
    let text = try extract(arguments[0], arguments[1])
    FileHandle.standardOutput.write(Data(text.utf8))
    if !text.hasSuffix("\n") { FileHandle.standardOutput.write(Data([10])) }
} catch let error as ExtractionFailure {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(error.code)
} catch {
    FileHandle.standardError.write(Data(("File extraction failed: \(error.localizedDescription)\n").utf8))
    exit(1)
}
