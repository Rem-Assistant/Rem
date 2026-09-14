import Foundation
import Network

/// Sends Wake-on-LAN magic packets to wake a sleeping Mac on the local network.
///
/// A magic packet is a UDP broadcast containing 6 bytes of 0xFF followed by
/// the target MAC address repeated 16 times (102 bytes total). The Mac's
/// network interface listens for this pattern even while sleeping.
///
/// Note: Wake-on-LAN over Wi-Fi is unreliable on Apple Silicon Macs.
/// Ethernet (including USB-C/Thunderbolt docks) is more reliable.
enum WakeOnLAN {

    /// Sends a Wake-on-LAN magic packet to the given MAC address.
    ///
    /// - Parameters:
    ///   - macAddress: The target MAC address (e.g. "AA:BB:CC:DD:EE:FF" or "AA-BB-CC-DD-EE-FF")
    ///   - port: UDP port to send on (default 9, the standard WoL port)
    ///   - broadcastAddress: Broadcast address (default "255.255.255.255")
    /// - Returns: True if the packet was sent successfully, false otherwise.
    @discardableResult
    static func send(
        macAddress: String,
        port: UInt16 = 9,
        broadcastAddress: String = "255.255.255.255"
    ) async -> Bool {
        guard let macBytes = parseMACAddress(macAddress) else {
            return false
        }

        let magicPacket = buildMagicPacket(macBytes: macBytes)

        return await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(broadcastAddress),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .udp
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(
                        content: magicPacket,
                        completion: .contentProcessed { error in
                            connection.cancel()
                            continuation.resume(returning: error == nil)
                        }
                    )
                case .failed, .cancelled:
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    // MARK: - Private

    /// Parses a MAC address string into 6 bytes.
    /// Accepts formats: "AA:BB:CC:DD:EE:FF", "AA-BB-CC-DD-EE-FF", "AABBCCDDEEFF"
    private static func parseMACAddress(_ address: String) -> [UInt8]? {
        let cleaned = address
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard cleaned.count == 12 else { return nil }

        var bytes: [UInt8] = []
        var index = cleaned.startIndex
        for _ in 0..<6 {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = nextIndex
        }
        return bytes
    }

    /// Builds a 102-byte magic packet: 6 bytes of 0xFF + MAC address repeated 16 times.
    private static func buildMagicPacket(macBytes: [UInt8]) -> Data {
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 {
            packet.append(contentsOf: macBytes)
        }
        return packet
    }
}
