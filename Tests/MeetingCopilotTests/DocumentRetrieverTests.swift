import XCTest
@testable import MeetingCopilot

final class DocumentRetrieverTests: XCTestCase {
    func testFindsRelevantDocument() {
        let rollout = MeetingDocument(
            url: URL(fileURLWithPath: "/tmp/APAC Rollout.txt"),
            text: "The APAC rollout is targeted for the end of August. Integration validation remains open."
        )
        let budget = MeetingDocument(
            url: URL(fileURLWithPath: "/tmp/Budget.txt"),
            text: "The approved marketing budget is 500,000 dollars."
        )

        let matches = DocumentRetriever.retrieve(
            query: "When is the APAC rollout planned?",
            documents: [budget, rollout]
        )

        XCTAssertEqual(matches.first?.document.name, "APAC Rollout.txt")
        XCTAssertTrue(matches.first?.excerpt.contains("August") == true)
    }

    func testReturnsNoMatchForUnsupportedQuestion() {
        let document = MeetingDocument(
            url: URL(fileURLWithPath: "/tmp/Plan.txt"),
            text: "The launch is planned for August."
        )

        XCTAssertTrue(
            DocumentRetriever.retrieve(
                query: "What is the legal retention policy?",
                documents: [document]
            ).isEmpty
        )
    }

    func testExtractsVisibleHTMLAndRemovesCode() {
        let html = """
        <html>
          <head><style>.secret { display:none }</style></head>
          <body>
            <h1>APAC Rollout</h1>
            <p>Target date: August 30 &amp; final review.</p>
            <script>window.privateToken = "do-not-index";</script>
          </body>
        </html>
        """

        let text = DocumentService.visibleText(fromHTML: html)

        XCTAssertTrue(text.contains("APAC Rollout"))
        XCTAssertTrue(text.contains("August 30 & final review."))
        XCTAssertFalse(text.contains("privateToken"))
        XCTAssertFalse(text.contains("display:none"))
    }
}
