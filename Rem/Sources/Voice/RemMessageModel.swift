import Combine
import Foundation

/// Represents the sender of a chat message
public enum RemMessageSender: Equatable {
    case user
    case ai
}

/// Message model for voice session chat (decoupled from any specific voice provider)
public struct RemMessageModel: Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let sender: RemMessageSender
    public let timestamp: Date

    public init(id: UUID = UUID(), text: String, sender: RemMessageSender, timestamp: Date) {
        self.id = id
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
    }
}
