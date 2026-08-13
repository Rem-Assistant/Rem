import Foundation

// MARK: - Backward-compatible typealiases
//
// Both iOS and Mac previously defined their own connection state enums.
// With the shared `GatewayConnectionState`, these typealiases keep existing
// code compiling without a rename-all refactor.
//
// When both targets include Shared/ files, add this file to both targets
// and REMOVE the old enum definitions from:
//   - iOS: RemClaw/Sources/Gateway/GatewayClientProtocol.swift (lines 54-77)
//   - Mac: RemClawMac/Sources/Gateway/MacGatewaySessionManager.swift (lines 619-642)

typealias RemGatewayConnectionState = GatewayConnectionState
typealias MacConnectionState = GatewayConnectionState

// Also unify the linked device types.
// Remove the old definitions from:
//   - iOS: RemClaw/Sources/Gateway/GatewaySessionManager.swift (LinkedDevice, DevicePlatform, DeviceToken, LinkedDevicesResponse)
//   - Mac: RemClawMac/Sources/Gateway/MacGatewaySessionManager.swift (MacLinkedDevice, MacDevicePlatform, MacDeviceToken, MacLinkedDevicesResponse)
//
// For Mac backward compat:
typealias MacLinkedDevice = LinkedDevice
typealias MacDevicePlatform = DevicePlatform
typealias MacDeviceToken = DeviceToken
typealias MacLinkedDevicesResponse = LinkedDevicesResponse

// Skill model backward compat (Mac used Mac-prefixed names):
typealias MacSkillEntry = SkillEntry
typealias MacSkillMissing = SkillMissing
typealias MacSkillRequirements = SkillRequirements
typealias MacSkillConfigCheck = SkillConfigCheck
typealias MacSkillInstallStep = SkillInstallStep
