import Foundation
import Testing

@testable import RemClaw

/// `.gateway` must be decodable-but-not-assignable. It attributes orchestrator-sweep
/// comments; no code path routes work to it (`askCloud()` always calls `runCloudAgent`
/// without consulting `assignedRuntime`). Exposing it in the picker offered a second
/// option labelled "Rem", indistinguishable from `.agentbox`, that silently lied about
/// where the work ran. Caught by Codex on #996.
struct TaskRuntimeKindTests {
    @Test("gateway is never offered as an assignable runtime")
    func gatewayNotAssignable() {
        #expect(!TaskRuntimeKind.assignableCases.contains(.gateway))
    }

    @Test("no two assignable runtimes share a display name")
    func assignableDisplayNamesAreUnique() {
        // The original bug was two entries both rendering "Rem" — unpickable by a human.
        let names = TaskRuntimeKind.assignableCases.map(\.displayName)
        #expect(names.count == Set(names).count)
    }

    @Test("every assignable runtime is a real case")
    func assignableAreKnownCases() {
        for runtime in TaskRuntimeKind.assignableCases {
            #expect(TaskRuntimeKind.allCases.contains(runtime))
        }
    }

    /// The decode half of #996: an unknown runtime must degrade to nil rather than throw
    /// and brick the whole comments array (that drift blanked Activity entirely).
    @Test("unknown runtime raw values decode to nil instead of throwing")
    func unknownRuntimeDegradesToNil() throws {
        let json = """
        {"id":"c1","task_id":"t1","author_kind":"cloud_agent","author_label":"Rem",
         "body":"hi","runtime":"some_future_runtime"}
        """.data(using: .utf8)!
        let comment = try JSONDecoder().decode(TaskComment.self, from: json)
        #expect(comment.runtime == nil)
        #expect(comment.body == "hi")
    }

    @Test("gateway still decodes and reads as cloud")
    func gatewayDecodes() throws {
        let json = """
        {"id":"c2","task_id":"t1","author_kind":"cloud_agent","author_label":"Rem",
         "body":"swept","runtime":"gateway"}
        """.data(using: .utf8)!
        let comment = try JSONDecoder().decode(TaskComment.self, from: json)
        #expect(comment.runtime == .gateway)
        #expect(comment.runtime?.isCloud == true)
    }
}
