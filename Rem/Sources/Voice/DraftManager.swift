import Combine
import Foundation
import SwiftUI

/// Type of draft being created
enum DraftType: String, Codable {
    case task
    case event
}

/// Draft data payload
struct DraftData: Codable {
    let title: String
    let priority: String?
    let dateTime: String?
    let durationMinutes: Int?
    let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case priority
        case dateTime = "date_time"
        case durationMinutes = "duration_minutes"
        case isDraft = "is_draft"
    }
}

/// Draft structure for tasks and events
struct Draft: Codable {
    let type: DraftType
    let data: DraftData
}

/// Manages the currently staged draft from the voice agent
@MainActor
class DraftManager: ObservableObject {
    @Published var currentDraft: Draft?
    @Published var isDraftVisible: Bool = false
    @Published var draftInsertionIndex: Int = 0
    @Published var isDraftPersisted: Bool = false
    @Published var createdTask: TaskEvent?

    func setDraft(_ draft: Draft, atMessageIndex index: Int) {
        currentDraft = draft
        draftInsertionIndex = index
        isDraftVisible = true
        isDraftPersisted = false
        createdTask = nil
    }

    func persistDraft() {
        isDraftPersisted = true
    }

    func setCreatedTask(_ task: TaskEvent) {
        createdTask = task
    }

    func clearDraft() {
        currentDraft = nil
        isDraftVisible = false
        draftInsertionIndex = 0
        isDraftPersisted = false
    }

    func clearCreatedTask() {
        createdTask = nil
        currentDraft = nil
        isDraftVisible = false
        isDraftPersisted = false
    }
}
