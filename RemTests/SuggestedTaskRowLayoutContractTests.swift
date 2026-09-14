import Foundation
import Testing

struct SuggestedTaskRowLayoutContractTests {
    @Test func suggestionControlsDoNotClaimUnboundedVerticalSpace() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = projectRoot
            .appendingPathComponent("Shared/Views/Tasks/SuggestedTaskRow.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!source.contains(".frame(maxHeight: .infinity)"))
        #expect(!source.contains("Spacer(minLength:"))
        #expect(source.contains(".frame(width: leftSlotWidth)"))
        #expect(source.contains(".frame(minHeight: 44)"))
    }
}
