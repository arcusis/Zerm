import SwiftUI

/// The dashboard's card surface.
///
/// Deliberately opaque rather than `.thinMaterial`. A material is a blur the compositor
/// redraws on every scroll frame, and the dashboard stacks eight of them inside one scroll
/// view — six metric cards, both chart cards and the footer button. Over the opaque window
/// background the two read almost identically, so the blur was paying for nothing.
extension View {
    func metricsCardSurface<S: InsettableShape>(_ shape: S) -> some View {
        background(
            shape
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                )
        )
    }

    func metricsCardSurface(cornerRadius: CGFloat = 16) -> some View {
        metricsCardSurface(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
