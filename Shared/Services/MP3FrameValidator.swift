import Foundation

/// Bounded structural validation for the buffered MP3 wire contract.
///
/// An optional ID3v2 tag is skipped using its synchsafe size, then two complete,
/// consecutive MPEG Layer III frames with stable version/sample rate are required.
enum MP3FrameValidator {
    private static let maxID3v2TagBytes = 256 * 1024
    private static let maxInspectedBytes = maxID3v2TagBytes + 64 * 1024

    static func isValid(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(maxInspectedBytes))
        guard let firstOffset = id3v2AudioOffset(bytes),
              let first = parseLayer3Frame(bytes, offset: firstOffset),
              let second = parseLayer3Frame(bytes, offset: firstOffset + first.length)
        else { return false }
        return second.versionBits == first.versionBits && second.sampleRate == first.sampleRate
    }

    private static func id3v2AudioOffset(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 3,
              bytes[0] == 0x49,
              bytes[1] == 0x44,
              bytes[2] == 0x33
        else { return 0 }
        guard bytes.count >= 10 else { return nil }
        let sizeBytes = bytes[6 ... 9]
        guard sizeBytes.allSatisfy({ ($0 & 0x80) == 0 }) else { return nil }
        let tagSize = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
        let audioOffset = 10 + tagSize
        guard audioOffset <= maxID3v2TagBytes, audioOffset <= bytes.count else { return nil }
        return audioOffset
    }

    private struct Frame {
        let length: Int
        let versionBits: Int
        let sampleRate: Int
    }

    private static func parseLayer3Frame(_ bytes: [UInt8], offset: Int) -> Frame? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let header = UInt32(bytes[offset]) << 24 |
            UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 |
            UInt32(bytes[offset + 3])
        guard (header & 0xFFE0_0000) == 0xFFE0_0000 else { return nil }

        let versionBits = Int((header >> 19) & 0x3)
        let layerBits = Int((header >> 17) & 0x3)
        guard versionBits != 0x1, layerBits == 0x1 else { return nil }

        let bitrateIndex = Int((header >> 12) & 0xF)
        let sampleRateIndex = Int((header >> 10) & 0x3)
        guard bitrateIndex > 0, bitrateIndex < 0xF, sampleRateIndex < 0x3 else { return nil }

        let mpeg1Bitrates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
        let mpeg2Bitrates = [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let baseSampleRates = [44_100, 48_000, 32_000]
        let bitrateKbps = (versionBits == 0x3 ? mpeg1Bitrates : mpeg2Bitrates)[bitrateIndex]
        let baseSampleRate = baseSampleRates[sampleRateIndex]
        let sampleRate = versionBits == 0x3
            ? baseSampleRate
            : versionBits == 0x2 ? baseSampleRate / 2 : baseSampleRate / 4
        let padding = Int((header >> 9) & 0x1)
        let coefficient = versionBits == 0x3 ? 144 : 72
        let frameLength = coefficient * bitrateKbps * 1_000 / sampleRate + padding
        guard frameLength >= 4, offset + frameLength <= bytes.count else { return nil }
        return Frame(length: frameLength, versionBits: versionBits, sampleRate: sampleRate)
    }
}
