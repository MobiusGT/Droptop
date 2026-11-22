import AppKit
import SwiftUI

@MainActor
final class ShelfViewController: NSHostingController<ShelfContentView> {
    init(
        store: ShelfStore,
        dropHighlight: ShelfDropHighlightState,
        onRequestClose: @escaping () -> Void,
        onRequestNewShelf: @escaping () -> Void,
        onRequestSettings: @escaping () -> Void,
        onRequestResize: @escaping (CGFloat) -> Void
    ) {
        super.init(
            rootView: ShelfContentView(
                store: store,
                dropHighlight: dropHighlight,
                onRequestClose: onRequestClose,
                onRequestNewShelf: onRequestNewShelf,
                onRequestSettings: onRequestSettings,
                onRequestResize: onRequestResize
            )
        )
        // CRITICAL: Prevent NSHostingController from propagating SwiftUI child widths onto
        // NSWindow.minSize so Auto Hide can cleanly shrink the window to 26pt/54pt strictly
        // inside `screen.frame` with ZERO bleeding into adjacent Virtual Desktops (Spaces)!
        sizingOptions = []
    }

    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let hostingView = view as? NSHostingView<ShelfContentView> {
            hostingView.sizingOptions = []
        }
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
    }
}
