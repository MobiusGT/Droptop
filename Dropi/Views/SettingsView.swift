import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let onClose: () -> Void
    let onKeyFocusChange: (Bool) -> Void

    @State private var isThemesExpanded = false
    @State private var isRecordingHotkey = false
    @State private var hasAccessibility = Permissions.isAccessibilityGranted

    private let themeColumns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7)
    ]

    private var palette: ResolvedShelfPalette {
        settings.shelfTheme.palette(variation: .identity, level: .off)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(palette.dividerColor)
                .frame(height: 0.75)
            settingsList
        }
        .frame(width: Constants.Shelf.settingsWidth, height: Constants.Shelf.settingsHeight)
        .background(
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                palette.backgroundTint
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: Constants.Shelf.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Shelf.cornerRadius)
                .strokeBorder(palette.borderColor, lineWidth: 1)
        )
        .preferredColorScheme(palette.preferredColorScheme)
        .onAppear {
            hasAccessibility = Permissions.isAccessibilityGranted
            ShelfManager.shared?.refreshPermissionsIfNeeded()
        }
        .onDisappear {
            if isRecordingHotkey {
                isRecordingHotkey = false
                onKeyFocusChange(false)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                onKeyFocusChange(false)
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(palette.primaryTextColor.opacity(0.85), palette.controlFill)
                    .frame(width: 20, height: 20)
                    .hoverDarken(in: Circle())
            }
            .buttonStyle(.plain)

            Text("Settings")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(palette.primaryTextColor)
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .center)
                .contentShape(Rectangle())
                .overlay(WindowDragGesture())

            Color.clear.frame(width: 16, height: 16)
        }
        .padding(.horizontal, Constants.Shelf.padding + 2)
        .padding(.vertical, 10)
    }

    private var settingsList: some View {
        ScrollView {
            VStack(spacing: 16) {
                appearanceSection
                behaviorSection
                screenEdgeSection
                otherTriggersSection
                generalSection
                versionFooter
            }
            .padding(Constants.Shelf.padding + 2)
        }
    }

    // MARK: - Collapsible Themes Section (Not a Dropdown!)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Appearance")

            VStack(spacing: 0) {
                Button {
                    withAnimation(.spring(duration: 0.24, bounce: 0.0)) {
                        isThemesExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 9) {
                        themeSwatchDot(for: settings.shelfTheme)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Themes")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(palette.primaryTextColor)

                            Text("\(settings.shelfTheme.displayName) · \(ShelfTheme.concreteThemes.count) themes (sorted by color)")
                                .font(.system(size: 10))
                                .foregroundStyle(palette.secondaryTextColor)
                        }

                        Spacer()

                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.secondaryTextColor)
                            .rotationEffect(.degrees(isThemesExpanded ? 90 : 0))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .hoverDarken(in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)

                if isThemesExpanded {
                    Rectangle()
                        .fill(palette.dividerColor)
                        .frame(height: 0.75)
                        .padding(.horizontal, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        themeGroup(title: "Adaptive (\(ShelfTheme.adaptiveThemes.count))", themes: ShelfTheme.adaptiveThemes)
                        themeGroup(title: "Dark (\(ShelfTheme.darkThemes.count))", themes: ShelfTheme.darkThemes)
                        themeGroup(title: "Light (\(ShelfTheme.lightThemes.count))", themes: ShelfTheme.lightThemes)
                    }
                    .padding(9)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(palette.rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(palette.borderColor.opacity(0.65), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryTextColor)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Shelf Color Variation")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(palette.primaryTextColor)

                        Text("Shifts shade of additional shelves")
                            .font(.system(size: 9.5))
                            .foregroundStyle(palette.secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 5) {
                    ForEach(ColorVariationLevel.allCases) { level in
                        colorVariationPill(level)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(palette.rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(palette.borderColor.opacity(0.65), lineWidth: 1)
            )
        }
    }

    private func colorVariationPill(_ level: ColorVariationLevel) -> some View {
        let isSelected = settings.colorVariationLevel == level
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.colorVariationLevel = level
            }
        } label: {
            Text(level.displayName)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? palette.accentForegroundColor : palette.primaryTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7.5)
                        .fill(isSelected ? palette.accentColor : palette.controlFill)
                )
                .hoverDarken(in: RoundedRectangle(cornerRadius: 7.5))
        }
        .buttonStyle(.plain)
    }

    private func themeGroup(title: String, themes: [ShelfTheme]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(palette.tertiaryTextColor)
                .tracking(0.5)
                .padding(.leading, 2)

            LazyVGrid(columns: themeColumns, spacing: 6) {
                ForEach(themes) { candidate in
                    themeCard(candidate)
                }
            }
        }
    }

    @ViewBuilder
    private func themeSwatchDot(for candidate: ShelfTheme) -> some View {
        switch candidate {
        case .random:
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        AngularGradient(
                            colors: [.red, .orange, .yellow, .green, .teal, .blue, .purple, .pink, .red],
                            center: .center
                        )
                    )
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.30), lineWidth: 1)
                    )
                Image(systemName: "shuffle")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
            }

        case .randomLight:
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.99, green: 0.87, blue: 0.90),
                                Color(red: 0.99, green: 0.96, blue: 0.82),
                                Color(red: 0.85, green: 0.96, blue: 0.95),
                                Color(red: 0.88, green: 0.90, blue: 0.99)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.black.opacity(0.16), lineWidth: 1)
                    )
                Image(systemName: "shuffle")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color(red: 0.16, green: 0.18, blue: 0.24))
            }

        case .randomDark:
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.24, green: 0.08, blue: 0.15),
                                Color(red: 0.08, green: 0.14, blue: 0.26),
                                Color(red: 0.07, green: 0.20, blue: 0.17)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.24), lineWidth: 1)
                    )
                Image(systemName: "shuffle")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color(red: 0.92, green: 0.94, blue: 1.0))
            }

        case .randomSystem:
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(red: 0.94, green: 0.95, blue: 0.98), location: 0.0),
                                .init(color: Color(red: 0.90, green: 0.92, blue: 0.97), location: 0.48),
                                .init(color: Color(red: 0.12, green: 0.14, blue: 0.22), location: 0.52),
                                .init(color: Color(red: 0.08, green: 0.10, blue: 0.16), location: 1.0)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(palette.borderColor, lineWidth: 1)
                    )
                Image(systemName: "shuffle")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.60), radius: 1.8, y: 0.5)
            }

        default:
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(candidate.swatchBackground)
                    .frame(width: 22, height: 22)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(candidate.borderColor, lineWidth: 1)
                    )

                Circle()
                    .fill(candidate.accentColor)
                    .frame(width: 9, height: 9)
            }
        }
    }

    private func themeCard(_ candidate: ShelfTheme) -> some View {
        let isActive = settings.shelfTheme == candidate
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                settings.shelfTheme = candidate
            }
        } label: {
            HStack(spacing: 6) {
                themeSwatchDot(for: candidate)

                Text(candidate.displayName)
                    .font(.system(size: 10.5, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(palette.primaryTextColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(palette.accentColor)
                }
            }
            .padding(.horizontal, 6.5)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8.5)
                    .fill(isActive ? palette.accentColor.opacity(palette.isLightTheme ? 0.16 : 0.20) : palette.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8.5)
                    .strokeBorder(isActive ? palette.accentColor.opacity(0.68) : palette.borderColor.opacity(0.50), lineWidth: 1)
            )
            .hoverDarken(in: RoundedRectangle(cornerRadius: 8.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Behavior & Auto Hide

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("Shelf Behavior")

            VStack(alignment: .leading, spacing: 7) {
                settingsToggle(
                    "Auto Hide",
                    subtitle: "Tucks shelves away into the screen edge",
                    icon: "sidebar.right",
                    isOn: $settings.autoHideEnabled
                )

                if settings.autoHideEnabled {
                    LazyVGrid(columns: themeColumns, spacing: 6) {
                        ForEach(AutoHideTabStyle.allCases) { style in
                            autoHideStylePill(style)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                }
            }
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(palette.rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(palette.borderColor.opacity(0.65), lineWidth: 1)
            )

            settingsToggle("Remove after drag out", icon: "arrow.up.forward.square", isOn: $settings.autoRemoveOnDragOut)
            settingsToggle("Auto-close shelf when empty", icon: "eye.slash", isOn: $settings.autoHideWhenEmpty)
            settingsToggle(
                "Show Copy button in shelf",
                subtitle: "Adds a Copy toolbar button next to Trash",
                icon: "doc.on.doc",
                isOn: $settings.showCopyButtonInShelf
            )
        }
    }

    private func autoHideStylePill(_ style: AutoHideTabStyle) -> some View {
        let isSelected = settings.autoHideTabStyle == style
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.autoHideTabStyle = style
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: style.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(style.displayName)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? palette.accentForegroundColor : palette.primaryTextColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? palette.accentColor : palette.controlFill)
            )
            .hoverDarken(in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Screen Edge

    private var screenEdgeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Screen-Edge Trigger")

            settingsToggle("Enable edge drag", icon: "rectangle.leftthird.inset.filled", isOn: $settings.edgeEnabled)
            if settings.edgeEnabled {
                settingsToggle("Left edge", icon: "arrow.left.to.line", isOn: $settings.leftEdgeEnabled)
                settingsToggle("Right edge", icon: "arrow.right.to.line", isOn: $settings.rightEdgeEnabled)
                settingsToggle("Edge glow indicator", icon: "sparkles", isOn: $settings.showEdgeIndicators)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11.5))
                            .foregroundStyle(palette.secondaryTextColor)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Window creation sensitivity")
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(palette.primaryTextColor)

                            Text("How close to the screen edge a drag triggers a new shelf")
                                .font(.system(size: 9.5))
                                .foregroundStyle(palette.secondaryTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 5) {
                        ForEach(EdgeCreationSensitivity.allCases) { sensitivity in
                            edgeSensitivityPill(sensitivity)
                        }
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(palette.rowFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .strokeBorder(palette.borderColor.opacity(0.65), lineWidth: 1)
                )
                .padding(.top, 2)
            }
        }
    }

    private func edgeSensitivityPill(_ sensitivity: EdgeCreationSensitivity) -> some View {
        let isSelected = settings.edgeCreationSensitivity == sensitivity
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                settings.edgeCreationSensitivity = sensitivity
            }
        } label: {
            Text(sensitivity.displayName)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? palette.accentForegroundColor : palette.primaryTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7.5)
                        .fill(isSelected ? palette.accentColor : palette.controlFill)
                )
                .hoverDarken(in: RoundedRectangle(cornerRadius: 7.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Other Triggers

    private var otherTriggersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Additional Triggers")

            settingsToggle("Shake while dragging", icon: "hand.draw", isOn: $settings.shakeEnabled)
            settingsToggle("Keyboard shortcut", icon: "keyboard", isOn: $settings.hotkeyEnabled)

            if settings.hotkeyEnabled {
                HStack {
                    Text("Shortcut")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryTextColor)

                    Spacer()

                    Button {
                        isRecordingHotkey.toggle()
                        onKeyFocusChange(isRecordingHotkey)
                    } label: {
                        Text(isRecordingHotkey ? "Press keys…" : settings.hotkeyDisplayString)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(palette.primaryTextColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isRecordingHotkey ? palette.accentColor.opacity(0.24) : palette.controlFill)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(isRecordingHotkey ? palette.accentColor.opacity(0.65) : palette.borderColor, lineWidth: 1)
                            )
                            .hoverDarken(in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .background(
                    HotkeyRecorder(isRecording: $isRecordingHotkey) { keyCode, modifiers in
                        settings.updateHotkey(keyCode: keyCode, modifiers: modifiers)
                        onKeyFocusChange(false)
                    }
                )

                if !hasAccessibility {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 10.5))
                            .foregroundStyle(palette.secondaryTextColor)
                        Text("Global hotkey needs Accessibility (edge drag works without it).")
                            .font(.system(size: 10))
                            .foregroundStyle(palette.secondaryTextColor)
                        Spacer()
                        Button("Grant") {
                            Permissions.requestAccessibility()
                        }
                        .font(.system(size: 10, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("General")

            settingsToggle("Show menu bar icon", icon: "menubar.rectangle", isOn: $settings.showMenuBarIcon)
            settingsToggle("Launch at login", icon: "power", isOn: $settings.launchAtLogin)
        }
    }

    private var appVersionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
    }

    private var versionFooter: some View {
        VStack(spacing: 8) {
            Rectangle()
                .fill(palette.dividerColor.opacity(0.6))
                .frame(height: 0.75)

            Text("Droptop Version \(appVersionString)")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(palette.tertiaryTextColor.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    // MARK: - Helpers

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(palette.tertiaryTextColor)
            .tracking(0.5)
    }

    private func settingsToggle(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11.5))
                .foregroundStyle(palette.secondaryTextColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(palette.primaryTextColor)

                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(palette.secondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onRecord: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = HotkeyRecorderView()
        view.onRecord = { [self] keyCode, modifiers in
            onRecord(keyCode, modifiers)
            isRecording = false
        }
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = context.coordinator.view {
            if isRecording {
                view.startRecording()
            } else {
                view.stopRecording()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var view: HotkeyRecorderView?
    }
}

final class HotkeyRecorderView: NSView {
    var onRecord: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    private var monitor: Any?

    func startRecording() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let relevant: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
            let modifiers = event.modifierFlags.intersection(relevant)
            guard !modifiers.isEmpty else { return event }
            self?.onRecord?(event.keyCode, modifiers)
            self?.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
