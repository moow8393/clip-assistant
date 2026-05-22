import XCTest
@testable import ClipAssistant

final class DetectorTests: XCTestCase {

    private func makeDetector(
        keywords: [String] = ["host", "password", "pw", "account", "authorization"],
        replacement: String = "***"
    ) throws -> ClipboardDetector {
        try ClipboardDetector(keywords: keywords, replacement: replacement)
    }

    // -----------------------------------------------------------------------
    // Test 1 — Format 1a: multi-line plain-text k-v
    // -----------------------------------------------------------------------
    func test1_format1a_multilineKV() throws {
        let text = """
        Employee Info:
        Name: John Smith
        Department: Engineering
        PW: MyP@ssw0rd
        Email: john.smith@company.com
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        XCTAssertTrue(redacted.contains("PW: ***"))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 2 — Format 1b: JSON-style quoted k-v
    // -----------------------------------------------------------------------
    func test2_format1b_jsonQuotedKV() throws {
        let text = """
        "Name": "John Smith"
        "Department": "Engineering"
        "PW": "MyP@ssw0rd"
        "Email": "john.smith@company.com"
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        // Group 2 absorbs the leading quote in the separator, so result is "PW": "***"
        // The trailing " is outside group 3 and is preserved
        XCTAssertTrue(redacted.contains("\"PW\": \"***\""))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 3 — Format 2: multi-line with trailing commas
    // -----------------------------------------------------------------------
    func test3_format2_trailingCommas() throws {
        let text = """
        Name: John Smith,
        Department: Engineering,
        PW: MyP@ssw0rd,
        Address: 123 Main Street,
        Email: john.smith@company.com,
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        // Comma is a group-3 terminator, so "MyP@ssw0rd" is replaced, trailing comma preserved
        XCTAssertTrue(redacted.contains("PW: ***,"))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 4 — Format 3: single-line comma-delimited
    // -----------------------------------------------------------------------
    func test4_format3_singleLineCSV() throws {
        let text = "Name: John Smith,PW: MyP@ssw0rd,Department: Engineering,Address: 123 Main St"
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
        XCTAssertTrue(redacted.contains("PW: ***"))
        XCTAssertFalse(redacted.contains("MyP@ssw0rd"))
    }

    // -----------------------------------------------------------------------
    // Test 5 — Log with Bearer Token and multiple keywords
    // -----------------------------------------------------------------------
    func test5_logWithBearerTokenMultiKeyword() throws {
        let text = """
        2024-01-15 10:23:45 INFO [api-gateway] Request started
        method: POST
        path: /api/v1/users
        Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.signature
        host: api.internal.company.com
        status: 200
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        XCTAssertEqual(keywords, ["authorization", "host"])
        // Bearer scheme prefix is absorbed into group 2, token body is group 3
        XCTAssertTrue(redacted.contains("Authorization: Bearer ***"))
        XCTAssertTrue(redacted.contains("host: ***"))
        XCTAssertFalse(redacted.contains("eyJhbGci"))
        XCTAssertFalse(redacted.contains("api.internal.company.com"))
    }

    // -----------------------------------------------------------------------
    // Test 6 — Format 4 table: presence match only, no redaction
    // -----------------------------------------------------------------------
    func test6_format4_tablePresenceOnly() throws {
        let text = """
        Employee Report 2024-01
        Name       PW          Address
        John       MyP@ssw0rd  123 Main St
        Jane       S3cr3t!     456 Oak Ave
        """
        let detector = try makeDetector()
        guard case .presenceMatch(let keywords) = detector.analyze(text: text) else {
            XCTFail("Expected presenceMatch — table headers have no k-v separator structure")
            return
        }
        XCTAssertEqual(keywords, ["pw"])
    }

    // -----------------------------------------------------------------------
    // Test 7 — Negative: word boundary blocks substring matches
    // -----------------------------------------------------------------------
    func test7_negative_wordBoundaryBlocks() throws {
        let text = """
        hostname=webserver01
        mypassword_field=test
        accountType=premium
        """
        let detector = try makeDetector()
        // "hostname=webserver01": "host" is at line start (no preceding \p{L}),
        // but "host" is followed by "n" (\p{L}), so (?!\p{L}) blocks both k-v and presence.
        // "mypassword_field=test": "m" precedes "password" (\p{L}), so (?<!\p{L}) blocks it.
        // "accountType=premium": "account" is at line start, but followed by "T" (\p{L}),
        //   so (?!\p{L}) blocks it.
        XCTAssertEqual(detector.analyze(text: text), .noMatch)
    }

    // -----------------------------------------------------------------------
    // Test 8 — Real-world mix: connection string + error message
    // -----------------------------------------------------------------------
    func test8_realWorldConnectionStringPlusError() throws {
        let text = """
        Connection Failed - Debug Info:
        Host: db.internal.company.com,
        Account: service_account_prod,
        Password: Db$3cr3tP@ss,
        Port: 5432,
        Database: production_db

        Last error: FATAL: password authentication failed for user "service_account_prod"
        """
        let detector = try makeDetector()
        guard case .kvMatch(let keywords, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        // "password authentication" has no separator after "password", so that line
        // does not produce a k-v match — presence pattern would catch it but k-v wins first.
        XCTAssertEqual(keywords, ["account", "host", "password"])
        XCTAssertTrue(redacted.contains("Host: ***"))
        XCTAssertTrue(redacted.contains("Account: ***"))
        XCTAssertTrue(redacted.contains("Password: ***"))
        // "password authentication failed" line: no k-v separator, so "password" in that
        // line is not replaced — this is the same behavior as Windows version
        XCTAssertTrue(redacted.contains("password authentication failed"))
        XCTAssertFalse(redacted.contains("db.internal.company.com"))
        XCTAssertFalse(redacted.contains("service_account_prod,"))   // comma-terminated line
        XCTAssertFalse(redacted.contains("Db$3cr3tP@ss"))
    }

    // -----------------------------------------------------------------------
    // Test 9 — $ in replacement token (back-reference escape)
    // -----------------------------------------------------------------------
    func test9_dollarSignInReplacement() throws {
        let text = "password: secret123"
        let detector = try ClipboardDetector(keywords: ["password"], replacement: "$REDACTED")
        guard case .kvMatch(_, let redacted) = detector.analyze(text: text) else {
            XCTFail("Expected kvMatch")
            return
        }
        // If $ is not escaped, "$R" would be interpreted as back-reference to group R (invalid),
        // resulting in empty string or crash. Correct output: "password: $REDACTED"
        XCTAssertTrue(redacted.contains("password: $REDACTED"))
    }

    // -----------------------------------------------------------------------
    // Test 10 — CJK keyword boundary
    // -----------------------------------------------------------------------
    func test10_cjkKeywordBoundary() throws {
        let hit = " 密碼: S3cr3t!"
        let miss = "test密碼=secret"

        let detector = try ClipboardDetector(keywords: ["密碼"], replacement: "***")

        guard case .kvMatch = detector.analyze(text: hit) else {
            XCTFail("Expected kvMatch for CJK keyword with valid separator")
            return
        }
        XCTAssertEqual(detector.analyze(text: miss), .noMatch)
    }
}
