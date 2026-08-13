import Foundation
import Testing
@testable import RemClaw

struct MP3FrameValidatorTests {
    private var fixture: Data {
        get throws {
            try Data(contentsOf: Self.fixtureURL)
        }
    }

    @Test func acceptsRealFFmpegEncodedFFprobeDecodableFixture() throws {
        #expect(MP3FrameValidator.isValid(try fixture))
    }

    @Test func rejectsID3OnlyBogusSyncTruncationWAVAndPCM() throws {
        let valid = try fixture
        let invalid: [Data] = [
            Data("ID3canonical-mp3".utf8),
            Data([0xFF, 0xFB, 0, 0, 0, 0, 0, 0]),
            valid.prefix(100),
            Data("RIFFgoogle-wav-fixture".utf8),
            Data(repeating: 0, count: 512),
        ]
        for audio in invalid {
            #expect(!MP3FrameValidator.isValid(audio))
        }
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Shared/Tests/Fixtures/talk-canonical.mp3")
}
