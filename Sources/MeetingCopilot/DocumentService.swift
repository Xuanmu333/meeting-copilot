import Foundation
import PDFKit
import UniformTypeIdentifiers

struct DocumentService {
    static let supportedTypes: [UTType] = [
        .pdf, .plainText, .rtf,
        UTType(filenameExtension: "md")!,
        .html,
        .commaSeparatedText,
        UTType(filenameExtension: "docx")!,
        UTType(filenameExtension: "pptx")!,
        UTType(filenameExtension: "xlsx")!
    ]

    func load(_ url: URL) throws -> MeetingDocument {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "pdf":
            guard let pdf = PDFDocument(url: url) else { throw CopilotError.unsupportedDocument }
            text = (0..<pdf.pageCount)
                .compactMap { pdf.page(at: $0)?.string }
                .joined(separator: "\n")
        case "txt", "md", "csv":
            text = try String(contentsOf: url, encoding: .utf8)
        case "html", "htm":
            let html = try String(contentsOf: url, encoding: .utf8)
            text = Self.visibleText(fromHTML: html)
        case "rtf":
            let attributed = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
            text = attributed.string
        case "docx", "pptx", "xlsx":
            text = try extractOfficeXML(url, fileExtension: ext)
        default:
            throw CopilotError.unsupportedDocument
        }

        let cleaned = text
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw CopilotError.unsupportedDocument }
        return MeetingDocument(url: url, text: cleaned)
    }

    static func visibleText(fromHTML html: String) -> String {
        html
            .replacingOccurrences(
                of: "<script\\b[^>]*>[\\s\\S]*?</script>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<style\\b[^>]*>[\\s\\S]*?</style>",
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(
                of: "<!--[\\s\\S]*?-->",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "</?(?:p|div|section|article|header|footer|h[1-6]|li|tr|br)\\b[^>]*>",
                with: "\n",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&#39;|&apos;", with: "'", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n+", with: "\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractOfficeXML(_ url: URL, fileExtension: String) throws -> String {
        let entries: [String]
        switch fileExtension {
        case "docx":
            entries = ["word/document.xml", "word/header*.xml", "word/footer*.xml"]
        case "pptx":
            entries = ["ppt/slides/slide*.xml", "ppt/notesSlides/notesSlide*.xml"]
        case "xlsx":
            entries = ["xl/sharedStrings.xml", "xl/worksheets/sheet*.xml"]
        default:
            throw CopilotError.unsupportedDocument
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path] + entries
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let xml = String(data: data, encoding: .utf8) else {
            throw CopilotError.unsupportedDocument
        }

        return xml
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

struct DocumentMatch {
    let document: MeetingDocument
    let excerpt: String
    let score: Int
}

enum DocumentRetriever {
    static func retrieve(query: String, documents: [MeetingDocument], limit: Int = 3) -> [DocumentMatch] {
        let terms = keywords(query)
        guard !terms.isEmpty else { return [] }

        return documents.compactMap { document in
            let chunks = chunk(document.text)
            guard let best = chunks
                .map({ text in
                    let lower = text.lowercased()
                    let score = terms.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
                    return (text, score)
                })
                .max(by: { $0.1 < $1.1 }),
                  best.1 > 0 else { return nil }

            return DocumentMatch(document: document, excerpt: best.0, score: best.1)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }

    private static func keywords(_ text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "and", "that", "this", "with", "from", "have", "what",
            "when", "where", "which", "would", "could", "about", "your", "our"
        ]
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    private static func chunk(_ text: String, size: Int = 1_200) -> [String] {
        guard text.count > size else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}
