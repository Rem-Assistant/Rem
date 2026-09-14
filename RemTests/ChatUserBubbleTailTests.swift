import Foundation
import Testing
@testable import Rem

/// The decorative "tail dots" that trail a user's sent bubble (ArcChatBubble style) are a
/// fun/personality flourish. The founder asked to stop shipping them unconditionally while keeping
/// the work behind a flag (#1371). These cover the pure gate so the default-off contract holds
/// without needing to render a SwiftUI body.
struct ChatUserBubbleTailTests {
    @Test func tailIsHiddenByDefaultWhenPersonalityFlagIsOff() {
        // The regression this locks: before #1371 a user bubble ALWAYS drew the tail. With the flag
        // off (the ship default) it must not.
        #expect(SharedRemChatView.showsUserBubbleTail(isUser: true, funPersonalityEnabled: false) == false)
    }

    @Test func tailShowsForUserBubblesOnlyWhenPersonalityFlagIsOn() {
        #expect(SharedRemChatView.showsUserBubbleTail(isUser: true, funPersonalityEnabled: true) == true)
    }

    @Test func assistantBubblesNeverDrawTheTailRegardlessOfFlag() {
        #expect(SharedRemChatView.showsUserBubbleTail(isUser: false, funPersonalityEnabled: false) == false)
        #expect(SharedRemChatView.showsUserBubbleTail(isUser: false, funPersonalityEnabled: true) == false)
    }

    @Test func flagDefaultsOffWithoutAnOverride() {
        // No launch-arg override and no UserDefaults key set → off. Guards the ship default so the
        // flourish cannot regress back to always-on.
        UserDefaults.standard.removeObject(forKey: SharedRemChatView.funPersonalityDefaultsKey)
        #expect(SharedRemChatView.funPersonalityEnabled == false)
    }
}
