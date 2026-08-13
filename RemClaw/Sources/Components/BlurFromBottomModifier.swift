import SwiftUI

struct SlideInFromBottom: ViewModifier {
    var isVisible: Bool
    var delay: Double = 0

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .blur(radius: isVisible ? 0 : 10)
            .offset(y: isVisible ? 0 : 50)
            .animation(.easeOut(duration: 0.5).delay(delay), value: isVisible)
    }
}

extension View {
    func blurFromBottom(_ isVisible: Bool, delay: Double = 0) -> some View {
        modifier(SlideInFromBottom(isVisible: isVisible, delay: delay))
    }
}
