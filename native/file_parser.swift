import Foundation
import AppKit
import PDFKit

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
    let url = URL(fileURLWithPath: path)
    let data: Data
    do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
    catch {
        throw fail("Cannot read the selected file: \(error.localizedDescription) Check Files and Folders access in System Settings, or choose a readable copy.")
    }
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
