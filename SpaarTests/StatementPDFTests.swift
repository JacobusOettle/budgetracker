import XCTest
import PDFKit
import UIKit
import SwiftData
@testable import Spaar

private final class RecordingJSONClient: LLMJSONCompleting {
    var replies: [String]
    var requests: [LLMRequest] = []
    init(_ replies: [String]) { self.replies = replies }
    func completeJSON(_ request: LLMRequest) async throws -> String {
        requests.append(request)
        guard !replies.isEmpty else { throw LLMError.emptyResponse }
        return replies.removeFirst()
    }
}

@MainActor
final class StatementPDFTests: XCTestCase {
    /// A real PDF with one text line per page, optionally password protected.
    /// A nil entry makes an image-only page with no text (like a scan).
    private func makePDF(_ pages: [String?], password: String? = nil) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        if let password {
            format.documentInfo = [
                kCGPDFContextUserPassword as String: password,
                kCGPDFContextOwnerPassword as String: password,
            ]
        }
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842), format: format)
        return renderer.pdfData { context in
            for text in pages {
                context.beginPage()
                if let text {
                    (text as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                } else {
                    UIColor.gray.setFill()
                    UIRectFill(CGRect(x: 40, y: 60, width: 300, height: 40))
                }
            }
        }
    }

    private func document(_ pages: [String?], password: String? = nil) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: makePDF(pages, password: password)))
    }

    // MARK: Chunking

    func testTextModeSendsPageTextInPartsOfThreePages() throws {
        let doc = try document((1...7).map { "Page \($0): 2026-10-0\($0) WOOLWORTHS 100.00" })
        let chunks = try StatementImport.pdfChunks(fileName: "fnb.pdf", document: doc, mode: .text)
        XCTAssertEqual(chunks.map(\.rows.count), [3, 3, 1])
        XCTAssertNil(chunks[0].pdf)
        XCTAssertTrue(chunks[0].rows[0].contains("--- Page 1 of 7 ---"))
        XCTAssertTrue(chunks[0].rows[0].contains("WOOLWORTHS"))
        let request = StatementImport.extractionRequest(chunks[2])
        XCTAssertNil(request.pdfData)
        XCTAssertTrue(request.user.contains("Page 7"))
        XCTAssertFalse(request.user.contains("CSV header"))
    }

    func testNativeModeAttachesJustThosePagesAsAPDF() throws {
        let doc = try document((1...4).map { "Statement page \($0)" })
        let chunks = try StatementImport.pdfChunks(fileName: "fnb.pdf", document: doc, mode: .native)
        XCTAssertEqual(chunks.map(\.pages), [[0, 1, 2], [3]])
        let request = StatementImport.extractionRequest(chunks[1])
        XCTAssertTrue(request.user.contains("page(s) 4"))
        let part = try XCTUnwrap(PDFDocument(data: XCTUnwrap(request.pdfData)))
        XCTAssertEqual(part.pageCount, 1)
        XCTAssertTrue(part.page(at: 0)?.string?.contains("Statement page 4") ?? false)
    }

    func testHalvingKeepsPagesAndRowsAligned() throws {
        let doc = try document(["a", "b", "c"])
        let chunk = try XCTUnwrap(StatementImport.pdfChunks(fileName: "x.pdf", document: doc, mode: .native).first)
        XCTAssertEqual(chunk.half(true).pages, [0])
        XCTAssertEqual(chunk.half(false).pages, [1, 2])
        XCTAssertEqual(chunk.half(false).rows.count, 2)
    }

    func testScannedPDFNeedsClaude() throws {
        let doc = try document([nil, nil])
        XCTAssertThrowsError(try StatementImport.pdfChunks(fileName: "scan.pdf", document: doc, mode: .text)) {
            XCTAssertEqual($0 as? StatementImport.ImportError, .scannedPDF("scan.pdf"))
        }
        XCTAssertEqual(try StatementImport.pdfChunks(fileName: "scan.pdf", document: doc, mode: .native).count, 1)
    }

    func testTooManyPagesIsRefused() throws {
        let doc = try document(Array(repeating: "x", count: StatementImport.maxPages + 1))
        XCTAssertThrowsError(try StatementImport.pdfChunks(fileName: "big.pdf", document: doc, mode: .native)) {
            XCTAssertEqual($0 as? StatementImport.ImportError, .tooManyPages(StatementImport.maxPages + 1))
        }
    }

    func testPasswordProtectedPDFIsUnlockedOnThePhoneAndSentWithoutPassword() throws {
        let doc = try document(["Secret statement 2026-10-01 SPAR 250.00"], password: "8001015009087")
        guard doc.isLocked else { throw XCTSkip("PDF renderer didn't encrypt in this environment") }

        XCTAssertThrowsError(try StatementImport.pdfChunks(fileName: "fnb.pdf", document: doc, mode: .native)) {
            XCTAssertEqual($0 as? StatementImport.ImportError, .locked("fnb.pdf"))
        }
        XCTAssertFalse(doc.unlock(withPassword: "wrong"))
        XCTAssertTrue(doc.unlock(withPassword: "8001015009087"))

        let chunk = try XCTUnwrap(StatementImport.pdfChunks(fileName: "fnb.pdf", document: doc, mode: .native).first)
        let sent = try XCTUnwrap(PDFDocument(data: XCTUnwrap(StatementImport.pdfData(for: chunk))))
        XCTAssertFalse(sent.isLocked, "the copy sent to the AI has no password")
        XCTAssertTrue(sent.page(at: 0)?.string?.contains("SPAR") ?? false)

        let text = try XCTUnwrap(StatementImport.pdfChunks(fileName: "fnb.pdf", document: doc, mode: .text).first)
        XCTAssertTrue(text.rows[0].contains("SPAR"))
    }

    // MARK: Request shape

    func testClaudeRequestPutsThePDFBeforeTheText() throws {
        var config = AIConfig()
        config.apply(AIPreset.named("anthropic"))
        let pdf = makePDF(["x"])
        let llm = LLMRequest(system: "s", user: "extract", schema: nil, maxTokens: 16000, effort: "low", pdfData: pdf)
        let request = try HTTPLLMClient.makeRequest(config: config, apiKey: "k", request: llm, timeout: 10, structured: true)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let message = try XCTUnwrap((body["messages"] as? [[String: Any]])?.first)
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.map { $0["type"] as? String }, ["document", "text"])
        let source = try XCTUnwrap(content[0]["source"] as? [String: String])
        XCTAssertEqual(source["type"], "base64")
        XCTAssertEqual(source["media_type"], "application/pdf")
        XCTAssertEqual(source["data"], pdf.base64EncodedString())
        XCTAssertFalse(source["data"]?.contains("\n") ?? true)
        XCTAssertEqual(content[1]["text"] as? String, "extract")
    }

    // MARK: End to end

    func testImporterReadsAPDFNatively() async throws {
        let container = try Persistence.inMemory()
        let doc = try document(["2026-10-01 CHECKERS 500.00", "2026-10-02 ENGEN 600.00"])
        let client = RecordingJSONClient([
            #"{"transactions":[{"date":"2026-10-01","description":"Checkers","amount":"500.00","kind":"spend","category":"Groceries"},{"date":"2026-10-02","description":"Engen","amount":"600.00","kind":"spend","category":"Fuel"}]}"#,
            #"{"budgets":[{"name":"Groceries","monthly_amount":"500.00","categories":["Groceries"]},{"name":"Fuel","monthly_amount":"600.00","categories":["Fuel"]}]}"#,
        ])
        let importer = StatementImporter(client: client, pdfMode: .native, calendar: TestCalendar.utc)
        await importer.run(files: [.pdf(name: "fnb.pdf", document: doc)], in: container.mainContext)
        XCTAssertEqual(importer.stage, .review)
        XCTAssertEqual(importer.plan?.payments.count, 2)
        XCTAssertNotNil(client.requests[0].pdfData)
        XCTAssertTrue(client.requests[0].user.contains("page(s) 1, 2"))
    }

    func testImporterSendsPDFTextToOtherProviders() async throws {
        let container = try Persistence.inMemory()
        let doc = try document(["2026-10-01 CHECKERS 500.00"])
        let client = RecordingJSONClient([
            #"{"transactions":[{"date":"2026-10-01","description":"Checkers","amount":"500.00","kind":"spend","category":"Groceries"}]}"#,
            #"{"budgets":[{"name":"Groceries","monthly_amount":"500.00","categories":["Groceries"]}]}"#,
        ])
        let importer = StatementImporter(client: client, pdfMode: .text, calendar: TestCalendar.utc)
        await importer.run(files: [.pdf(name: "fnb.pdf", document: doc)], in: container.mainContext)
        XCTAssertEqual(importer.stage, .review)
        XCTAssertNil(client.requests[0].pdfData)
        XCTAssertTrue(client.requests[0].user.contains("CHECKERS"))
    }
}
