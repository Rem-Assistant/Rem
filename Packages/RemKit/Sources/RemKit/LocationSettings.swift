import Foundation

public enum RemLocationMode: String, Codable, Sendable, CaseIterable {
    case off
    case whileUsing
    case always
}
