import SwiftUI

/// Darkens a button's surface on pointer hover to clearly signify it is targeted,
/// adapting cleanly to both light and dark appearances (including System Glass).
struct HoverDarkenModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var isActive: Bool = true
    var onHoverChange: ((Bool) -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let isLight = (colorScheme == .light)
        let effectiveHovered = isActive && isHovered
        content
            .overlay(
                shape
                    .fill(Color.black.opacity(effectiveHovered ? (isLight ? 0.18 : 0.36) : 0.0))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(
                        Color.black.opacity(effectiveHovered ? (isLight ? 0.14 : 0.24) : 0.0),
                        lineWidth: 0.75
                    )
                    .allowsHitTesting(false)
            )
            .clipShape(shape)
            .contentShape(shape)
            .animation(.easeOut(duration: 0.10), value: effectiveHovered)
            .onHover { hovering in
                let next = isActive ? hovering : false
                if isHovered != next {
                    isHovered = next
                    onHoverChange?(next)
                }
            }
            .onChange(of: isActive) { _, active in
                if !active && isHovered {
                    isHovered = false
                    onHoverChange?(false)
                }
            }
            .onDisappear {
                if isHovered {
                    isHovered = false
                    onHoverChange?(false)
                }
            }
    }
}

extension View {
    func hoverDarken<S: InsettableShape>(
        in shape: S,
        isActive: Bool = true,
        onHoverChange: ((Bool) -> Void)? = nil
    ) -> some View {
        modifier(HoverDarkenModifier(shape: shape, isActive: isActive, onHoverChange: onHoverChange))
    }
}
