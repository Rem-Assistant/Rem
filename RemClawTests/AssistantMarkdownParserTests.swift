import Testing
@testable import RemClaw

struct AssistantMarkdownParserTests {
    @Test func splitsFencedCodeFromMarkdownText() {
        let markdown = """
        Here is **Swift**:

        ```swift
        let value = "**not bold**"
        print(value)
        ```

        Done with `inline`.
        """

        #expect(AssistantMarkdownParser.parse(markdown) == [
            .text("Here is **Swift**:"),
            .code(language: "swift", text: "let value = \"**not bold**\"\nprint(value)"),
            .text("Done with `inline`.")
        ])
    }

    @Test func normalizesHeadingsAndRulesOnlyInTextSegments() {
        let markdown = """
        ## Summary
        ---
        ```text
        ## keep literal
        ---
        ```
        """

        #expect(AssistantMarkdownParser.parse(markdown) == [
            .text("**Summary**"),
            .code(language: "text", text: "## keep literal\n---")
        ])
    }

    @Test func unclosedStreamingFenceStillProducesCodeBlock() {
        let markdown = """
        Working:
        ```bash
        rem run
        """

        #expect(AssistantMarkdownParser.parse(markdown) == [
            .text("Working:"),
            .code(language: "bash", text: "rem run")
        ])
    }
}
