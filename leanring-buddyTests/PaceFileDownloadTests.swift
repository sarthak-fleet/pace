//
//  PaceFileDownloadTests.swift
//  leanring-buddyTests
//

import Foundation
import Testing

@testable import Pace

struct PaceFileDownloadTests {
    @Test func validatorAcceptsPlainHTTPSURL() async throws {
        let url = PaceFileDownloadURLValidator.validatedDownloadURL(
            from: " https://example.com/report.pdf "
        )
        #expect(url?.absoluteString == "https://example.com/report.pdf")
    }

    @Test func validatorRejectsNonHTTPSchemesAndCredentials() async throws {
        #expect(PaceFileDownloadURLValidator.validatedDownloadURL(from: "ftp://example.com/a") == nil)
        #expect(PaceFileDownloadURLValidator.validatedDownloadURL(from: "file:///etc/passwd") == nil)
        #expect(PaceFileDownloadURLValidator.validatedDownloadURL(from: "https://user:pass@example.com/a") == nil)
        #expect(PaceFileDownloadURLValidator.validatedDownloadURL(from: "not a url") == nil)
        #expect(PaceFileDownloadURLValidator.validatedDownloadURL(from: "") == nil)
    }

    @Test func sanitizerStripsPathSeparatorsAndTraversal() async throws {
        let downloadURL = URL(string: "https://example.com/files/report.pdf")!
        #expect(
            PaceDownloadFilenameSanitizer.sanitizedFilename(
                suggestedFilename: "../../etc/passwd",
                downloadURL: downloadURL
            ) == "passwd"
        )
        #expect(
            PaceDownloadFilenameSanitizer.sanitizedFilename(
                suggestedFilename: nil,
                downloadURL: downloadURL
            ) == "report.pdf"
        )
    }

    @Test func sanitizerFallsBackWhenNothingUsable() async throws {
        let downloadURL = URL(string: "https://example.com")!
        let filename = PaceDownloadFilenameSanitizer.sanitizedFilename(
            suggestedFilename: "...",
            downloadURL: downloadURL
        )
        #expect(filename == PaceDownloadFilenameSanitizer.fallbackFilename)
    }

    @Test func collisionFreeFilenameAppendsCounterBeforeExtension() async throws {
        let existingFilenames: Set<String> = ["report.pdf", "report 2.pdf"]
        #expect(
            PaceDownloadFilenameSanitizer.collisionFreeFilename(
                "report.pdf",
                existingFilenames: existingFilenames
            ) == "report 3.pdf"
        )
        #expect(
            PaceDownloadFilenameSanitizer.collisionFreeFilename(
                "fresh.pdf",
                existingFilenames: existingFilenames
            ) == "fresh.pdf"
        )
    }

    @Test func toolCallJSONParsesIntoDownloadFileAction() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        downloading that.
        <tool_calls>
        [
          [
            {"tool":"download_file","url":"https://example.com/report.pdf","name":"report.pdf"}
          ]
        ]
        </tool_calls>
        """)

        guard case .downloadFile(let downloadRequest) = parseResult.actions.first else {
            Issue.record("Expected download_file to become downloadFile")
            return
        }
        #expect(downloadRequest.url.absoluteString == "https://example.com/report.pdf")
        #expect(downloadRequest.suggestedFilename == "report.pdf")
    }

    @Test func toolCallWithInvalidURLIsRejectedBeforeExecution() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        <tool_calls>
        [[{"tool":"download_file","url":"file:///etc/passwd"}]]
        </tool_calls>
        """)
        #expect(parseResult.actions.isEmpty)
    }

    @Test func v10ParameterizedFileDownloadParses() async throws {
        let parseResult = PaceActionTagParser.parseActions(from: """
        {
          "spokenText": "Downloading the report.",
          "intent": "action",
          "payload": {
            "name": "File.download",
            "args": {"url": "https://example.com/report.pdf", "filename": "q2-report.pdf"}
          }
        }
        """)

        guard case .downloadFile(let downloadRequest) = parseResult.actions.first else {
            Issue.record("Expected File.download to become downloadFile")
            return
        }
        #expect(downloadRequest.url.host == "example.com")
        #expect(downloadRequest.suggestedFilename == "q2-report.pdf")
    }

    @Test func downloadActionRequiresExplicitApproval() async throws {
        let downloadAction = PaceParsedAction.downloadFile(PaceFileDownloadRequest(
            url: URL(string: "https://example.com/report.pdf")!,
            suggestedFilename: nil
        ))
        let executionPlan = PaceActionExecutionPlan.serial(actions: [downloadAction])
        #expect(PaceActionApprovalPolicy.requiresExplicitApproval(for: executionPlan))
        #expect(downloadAction.approvalDescription.contains("https://example.com/report.pdf"))
    }
}
