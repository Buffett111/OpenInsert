import Foundation
import XCTest
@testable import OpenInsertCore

final class GeminiAPIKeyTests: XCTestCase {
    // Synthetic credentials only. These tests check local transport safety, not authentication.
    private let modernKey = "AQ." + String(repeating: "synthetic_auth-key_", count: 30)

    func testOpaqueAuthorizationKeyIsAcceptedByLiveBatchAndCleanup() throws {
        XCTAssertGreaterThan(modernKey.count, 256)
        let pasted = " \n" + modernKey + "\r\n "
        XCTAssertEqual(try GeminiAPIKey.validate(pasted), modernKey)
        try GeminiLiveTranscriber.validateConfiguration(apiKey: pasted)
        let requests = [
            try GeminiLiveProtocol.request(apiKey: pasted),
            try GeminiClient.makeRequest(audio: Data([0, 0]), mimeType: "audio/wav", apiKey: pasted, options: DictationOptions()),
            try GeminiClient.makePolishRequest(transcript: "Hello.", apiKey: pasted, options: DictationOptions())
        ]
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), modernKey)
            XCTAssertNil(request.url?.query)
            XCTAssertFalse(request.url?.absoluteString.contains(modernKey) ?? true)
            XCTAssertFalse(request.httpBody.map { String(decoding: $0, as: UTF8.self).contains(modernKey) } ?? false)
        }
    }

    func testLocalKeyValidationDoesNotInventAnAuthenticationFormat() throws {
        // The backend decides if these safe opaque values authenticate. A local regex
        // must not reject future punctuation, prefixes, or lengths based on old examples.
        for value in ["synthetic", "AQ.synthetic.with.dots_-+/=", String(repeating: "x", count: GeminiAPIKey.maximumBytes)] {
            XCTAssertEqual(try GeminiAPIKey.validate(value), value)
        }
    }

    func testKeyIssuesAreSpecificRedactedAndConsistentAcrossTransports() async {
        let client = GeminiClient()
        let cases: [(String, GeminiAPIKeyValidationError)] = [
            (" \r\n", .missing),
            (String(repeating: "private", count: 1_171), .tooLong),
            ("private key", .containsWhitespace),
            ("private\r\nInjected:secret", .containsWhitespace),
            ("private\tkey", .containsWhitespace),
            ("private\u{00}key", .invalidCharacters),
            ("private\u{7f}key", .invalidCharacters),
            ("private\u{200b}key", .invalidCharacters),
            ("\u{200b}private", .invalidCharacters),
            ("private密鑰", .invalidCharacters)
        ]
        for (value, issue) in cases {
            XCTAssertThrowsError(try GeminiAPIKey.validate(value)) { error in
                XCTAssertEqual(error as? GeminiAPIKeyValidationError, issue)
                XCTAssertFalse(error.localizedDescription.contains("private"))
                XCTAssertFalse(error.localizedDescription.contains("Injected"))
            }
            XCTAssertThrowsError(try GeminiLiveTranscriber.validateConfiguration(apiKey: value)) {
                XCTAssertEqual($0 as? GeminiLiveError, .invalidAPIKey(issue))
            }
            XCTAssertThrowsError(try GeminiClient.makePolishRequest(transcript: "Hello.", apiKey: value, options: DictationOptions())) {
                XCTAssertEqual($0 as? GeminiAPIKeyValidationError, issue)
            }
            do {
                _ = try await client.polish(transcript: "Hello.", apiKey: value, options: DictationOptions())
                XCTFail("Expected local format error before network request")
            } catch {
                XCTAssertEqual(error as? GeminiAPIKeyValidationError, issue)
            }
        }
    }

    func testPublicPreflightIdentifiesEachConfigurationFieldWithoutConnecting() throws {
        XCTAssertThrowsError(try GeminiLiveTranscriber.validateConfiguration(apiKey: modernKey, model: "https://private.invalid")) {
            XCTAssertEqual($0 as? GeminiLiveError, .invalidModel)
            XCTAssertFalse($0.localizedDescription.contains("private.invalid"))
        }
        XCTAssertThrowsError(try GeminiLiveTranscriber.validateConfiguration(apiKey: modernKey, languageCodes: ["private invalid code"])) {
            XCTAssertEqual($0 as? GeminiLiveError, .invalidLanguageCodes)
        }
        XCTAssertThrowsError(try GeminiLiveTranscriber.validateConfiguration(apiKey: modernKey, vocabulary: [String(repeating: "x", count: 513)])) {
            XCTAssertEqual($0 as? GeminiLiveError, .invalidVocabulary)
        }
        try GeminiLiveTranscriber.validateConfiguration(apiKey: modernKey, model: " gemini-3.5-transcribe-live\n", languageCodes: ["cmn-Hans-CN", "en-US"])
    }
}
