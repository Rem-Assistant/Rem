import Foundation
import Testing

@testable import RemClaw

/// The first agent-driven browser screenshot rendered as a screenful of raw base64
/// ("AAAAAAA…") because the agent wrote the image INSIDE a sentence:
///
///   Here's example.com: ![screenshot of example.com](data:image/jpeg;base64,…)
///
/// The parser only accepted a *standalone* image line — true of tool results (the gateway
/// patch emits the data-URL on its own line) but not of the assistant's own prose. One
/// prefix dumped the whole payload into the text branch. Verified in-app 2026-07-17.
struct AssistantMarkdownInlineImageTests {
    private let dataURL = "data:image/jpeg;base64,/9j/4AAQSkZJRg=="

    @Test("an image after prose on the same line still renders as an image")
    func inlineImageAfterProse() throws {
        let segments = AssistantMarkdownParser.parse("Here's example.com: ![shot](\(dataURL))")
        let images = segments.compactMap { seg -> String? in
            if case .image(_, let url) = seg { return url }
            return nil
        }
        #expect(images == [dataURL], "the data-URL must become an image segment, not text")
    }

    @Test("the prose around an inline image is preserved")
    func proseAroundImageKept() throws {
        let segments = AssistantMarkdownParser.parse("Here's the page: ![shot](\(dataURL)) all done")
        let texts = segments.compactMap { seg -> String? in
            if case .text(let t) = seg { return t }
            return nil
        }
        #expect(texts.contains { $0.contains("Here's the page:") })
        #expect(texts.contains { $0.contains("all done") })
    }

    @Test("no base64 payload ever leaks into a text segment")
    func base64NeverRendersAsText() throws {
        // The actual user-visible bug: a wall of "AAAA…" in the transcript.
        let segments = AssistantMarkdownParser.parse("Here's example.com: ![shot](\(dataURL))")
        for seg in segments {
            if case .text(let t) = seg {
                #expect(!t.contains("base64"), "raw data-URL leaked into text: \(t.prefix(60))")
            }
        }
    }

    @Test("a standalone image line still works (tool-result path unchanged)")
    func standaloneStillWorks() throws {
        let segments = AssistantMarkdownParser.parse("![shot](\(dataURL))")
        let images = segments.compactMap { seg -> String? in
            if case .image(_, let url) = seg { return url }
            return nil
        }
        #expect(images == [dataURL])
    }

    @Test("trailing prose is not swallowed into the URL")
    func trailingProseNotSwallowed() throws {
        // Taking the LAST ")" instead of the first would capture " (see above)" into the
        // URL and break the image.
        let parsed = AssistantMarkdownParser.parseImageInLine("look: ![a](\(dataURL)) (see above)")
        #expect(parsed?.url == dataURL)
        #expect(parsed?.after == "(see above)")
    }

    @Test("plain prose is still plain prose")
    func proseUnaffected() throws {
        let segments = AssistantMarkdownParser.parse("Just a normal sentence with no image.")
        for seg in segments {
            if case .image = seg { Issue.record("prose must not produce an image segment") }
        }
    }
}
