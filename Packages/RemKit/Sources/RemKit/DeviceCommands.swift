import Foundation

public enum RemGatewayDeviceCommand: String, Codable, Sendable {
    case status = "device.status"
    case info = "device.info"
}

public enum RemBatteryState: String, Codable, Sendable {
    case unknown
    case unplugged
    case charging
    case full
}

public enum RemThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum RemNetworkPathStatus: String, Codable, Sendable {
    case satisfied
    case unsatisfied
    case requiresConnection
}

public enum RemNetworkInterfaceType: String, Codable, Sendable {
    case wifi
    case cellular
    case wired
    case other
}

public struct RemBatteryStatusPayload: Codable, Sendable, Equatable {
    public var level: Double?
    public var state: RemBatteryState
    public var lowPowerModeEnabled: Bool

    public init(level: Double?, state: RemBatteryState, lowPowerModeEnabled: Bool) {
        self.level = level
        self.state = state
        self.lowPowerModeEnabled = lowPowerModeEnabled
    }
}

public struct RemThermalStatusPayload: Codable, Sendable, Equatable {
    public var state: RemThermalState

    public init(state: RemThermalState) {
        self.state = state
    }
}

public struct RemStorageStatusPayload: Codable, Sendable, Equatable {
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var usedBytes: Int64

    public init(totalBytes: Int64, freeBytes: Int64, usedBytes: Int64) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.usedBytes = usedBytes
    }
}

public struct RemNetworkStatusPayload: Codable, Sendable, Equatable {
    public var status: RemNetworkPathStatus
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var interfaces: [RemNetworkInterfaceType]

    public init(
        status: RemNetworkPathStatus,
        isExpensive: Bool,
        isConstrained: Bool,
        interfaces: [RemNetworkInterfaceType])
    {
        self.status = status
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.interfaces = interfaces
    }
}

public struct RemDeviceStatusPayload: Codable, Sendable, Equatable {
    public var battery: RemBatteryStatusPayload
    public var thermal: RemThermalStatusPayload
    public var storage: RemStorageStatusPayload
    public var network: RemNetworkStatusPayload
    public var uptimeSeconds: Double

    public init(
        battery: RemBatteryStatusPayload,
        thermal: RemThermalStatusPayload,
        storage: RemStorageStatusPayload,
        network: RemNetworkStatusPayload,
        uptimeSeconds: Double)
    {
        self.battery = battery
        self.thermal = thermal
        self.storage = storage
        self.network = network
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct RemDeviceInfoPayload: Codable, Sendable, Equatable {
    public var deviceName: String
    public var modelIdentifier: String
    public var systemName: String
    public var systemVersion: String
    public var appVersion: String
    public var appBuild: String
    public var locale: String

    public init(
        deviceName: String,
        modelIdentifier: String,
        systemName: String,
        systemVersion: String,
        appVersion: String,
        appBuild: String,
        locale: String)
    {
        self.deviceName = deviceName
        self.modelIdentifier = modelIdentifier
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.locale = locale
    }
}
