#if canImport(UIKit)
import UIKit
#endif
import Combine
import Foundation

/// Provides device status and info for the gateway AI agent.
/// Reports battery, thermal state, storage, and device model information.
enum DeviceStatusService {

    // MARK: - device.status

    static func getStatus() -> DeviceStatusPayload {
        #if canImport(UIKit)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true

        let batteryLevel = Double(device.batteryLevel)
        let batteryState: String = {
            switch device.batteryState {
            case .unknown: return "unknown"
            case .unplugged: return "unplugged"
            case .charging: return "charging"
            case .full: return "full"
            @unknown default: return "unknown"
            }
        }()

        let thermalState: String = {
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }()

        let lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        let (total, available) = diskSpace()

        return DeviceStatusPayload(
            batteryLevel: batteryLevel >= 0 ? batteryLevel : -1,
            batteryState: batteryState,
            thermalState: thermalState,
            lowPowerMode: lowPowerMode,
            diskTotalBytes: total,
            diskAvailableBytes: available)
        #else
        return DeviceStatusPayload(
            batteryLevel: -1,
            batteryState: "unknown",
            thermalState: "unknown",
            lowPowerMode: false,
            diskTotalBytes: nil,
            diskAvailableBytes: nil)
        #endif
    }

    // MARK: - device.info

    static func getInfo() -> DeviceInfoPayload {
        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        timeFmt.timeZone = .current
        let localTime = timeFmt.string(from: Date())
        let tzId = TimeZone.current.identifier
        let tzAbbrev = TimeZone.current.abbreviation() ?? tzId

        #if canImport(UIKit)
        let device = UIDevice.current
        let process = ProcessInfo.processInfo

        let thermalState: String = {
            switch process.thermalState {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }()

        return DeviceInfoPayload(
            name: device.name,
            model: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            identifierForVendor: device.identifierForVendor?.uuidString,
            localTime: localTime,
            timeZone: tzId,
            timeZoneAbbreviation: tzAbbrev,
            processInfo: DeviceProcessInfo(
                processorCount: process.processorCount,
                physicalMemoryBytes: Int64(process.physicalMemory),
                osVersion: process.operatingSystemVersionString,
                thermalState: thermalState))
        #else
        let process = ProcessInfo.processInfo
        return DeviceInfoPayload(
            name: process.hostName,
            model: "Unknown",
            systemName: "Unknown",
            systemVersion: process.operatingSystemVersionString,
            identifierForVendor: nil,
            localTime: localTime,
            timeZone: tzId,
            timeZoneAbbreviation: tzAbbrev,
            processInfo: DeviceProcessInfo(
                processorCount: process.processorCount,
                physicalMemoryBytes: Int64(process.physicalMemory),
                osVersion: process.operatingSystemVersionString,
                thermalState: "unknown"))
        #endif
    }

    // MARK: - Private

    private static func diskSpace() -> (total: Int64?, available: Int64?) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else { return (nil, nil) }
        let total = values.volumeTotalCapacity.map(Int64.init)
        let available = values.volumeAvailableCapacityForImportantUsage
        return (total, available)
    }
}
