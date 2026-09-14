import Foundation

public enum RemCameraCommand: String, Codable, Sendable {
    case list = "camera.list"
    case snap = "camera.snap"
    case clip = "camera.clip"
}

public enum RemCameraFacing: String, Codable, Sendable {
    case back
    case front
}

public enum RemCameraImageFormat: String, Codable, Sendable {
    case jpg
    case jpeg
}

public enum RemCameraVideoFormat: String, Codable, Sendable {
    case mp4
}

public struct RemCameraSnapParams: Codable, Sendable, Equatable {
    public var facing: RemCameraFacing?
    public var maxWidth: Int?
    public var quality: Double?
    public var format: RemCameraImageFormat?
    public var deviceId: String?
    public var delayMs: Int?

    public init(
        facing: RemCameraFacing? = nil,
        maxWidth: Int? = nil,
        quality: Double? = nil,
        format: RemCameraImageFormat? = nil,
        deviceId: String? = nil,
        delayMs: Int? = nil)
    {
        self.facing = facing
        self.maxWidth = maxWidth
        self.quality = quality
        self.format = format
        self.deviceId = deviceId
        self.delayMs = delayMs
    }
}

public struct RemCameraClipParams: Codable, Sendable, Equatable {
    public var facing: RemCameraFacing?
    public var durationMs: Int?
    public var includeAudio: Bool?
    public var format: RemCameraVideoFormat?
    public var deviceId: String?

    public init(
        facing: RemCameraFacing? = nil,
        durationMs: Int? = nil,
        includeAudio: Bool? = nil,
        format: RemCameraVideoFormat? = nil,
        deviceId: String? = nil)
    {
        self.facing = facing
        self.durationMs = durationMs
        self.includeAudio = includeAudio
        self.format = format
        self.deviceId = deviceId
    }
}
