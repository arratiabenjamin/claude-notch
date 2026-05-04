// SettingsView.swift
// Minimal preferences pane shown from the menu-bar item. Persists every
// control directly into UserDefaults using the same keys NotificationService
// and AppController already read from. No bindings to a separate model —
// the four toggles all live in UserDefaults so other components keep
// working without subscribing to a new ObservableObject.
//
// Keys (kept in sync with the rest of the app):
//   - notify_threshold_s         : Double, seconds (default 90)
//   - default_position           : String, one of PanelCorner.rawValue
//   - notify_on_multi_session    : Bool   (default true)
//   - panelOriginX / panelOriginY: Double (cleared by "Reset position")
import SwiftUI
import AppKit

/// Public so AppController can place the panel at the user's preferred corner
/// when there is no saved position.
enum PanelCorner: String, CaseIterable, Identifiable {
    case topRight    = "top-right"
    case topLeft     = "top-left"
    case bottomRight = "bottom-right"
    case bottomLeft  = "bottom-left"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topRight:    return "Top right"
        case .topLeft:     return "Top left"
        case .bottomRight: return "Bottom right"
        case .bottomLeft:  return "Bottom left"
        }
    }
}

struct SettingsView: View {
    /// Closure invoked when the user clicks "Reset position". The owning
    /// AppController is responsible for clearing the saved origin AND moving
    /// the floating panel to the corner currently selected here.
    var onResetPosition: () -> Void
    /// Quit the app from the same window — saves a trip to the menu bar.
    var onQuit: () -> Void

    @AppStorage("notify_threshold_s") private var thresholdSeconds: Double = 90
    @AppStorage("default_position") private var defaultPositionRaw: String = PanelCorner.topRight.rawValue
    @AppStorage("notify_on_multi_session") private var notifyOnMultiSession: Bool = true
    @AppStorage("use_notch_mode") private var useNotchMode: Bool = true
    @AppStorage("use_notch_mode_explicitly_set") private var useNotchModeExplicitlySet: Bool = false

    /// String-bound mirror of `thresholdSeconds` so the user can type freely
    /// without losing focus on every keystroke.
    @State private var thresholdInput: String = ""

    /// True when the user is on a Mac with a hardware notch (MacBook Pro 14"/16"
    /// post-2021, MacBook Air post-2022). Drives whether we show the toggle at all.
    private var hasNotchHardware: Bool {
        if #available(macOS 12.0, *) {
            return (NSScreen.main?.safeAreaInsets.top ?? 0) > 0
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Notch")
                .font(.system(size: 14, weight: .semibold))

            // Threshold
            VStack(alignment: .leading, spacing: 4) {
                Text("Notification threshold (seconds)")
                    .font(.system(size: 12, weight: .medium))
                HStack {
                    TextField("90", text: $thresholdInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { commitThreshold() }
                    Stepper("",
                            value: $thresholdSeconds,
                            in: 5...3600,
                            step: 5)
                        .labelsHidden()
                        .onChange(of: thresholdSeconds) { _, new in
                            thresholdInput = String(Int(new))
                        }
                    Spacer()
                }
                Text("A turn longer than this triggers a notification.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Notch mode (only shown on Macs with a hardware notch)
            if hasNotchHardware {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Use notch as Dynamic Island", isOn: Binding(
                        get: { useNotchMode },
                        set: { newValue in
                            useNotchMode = newValue
                            useNotchModeExplicitlySet = true
                            NotificationCenter.default.post(
                                name: .claudeNotchModeDidChange,
                                object: nil
                            )
                        }
                    ))
                    Text("Panel sits on the notch and expands when you hover over it.\nTurn off to use the classic floating pill.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            // Default position
            VStack(alignment: .leading, spacing: 4) {
                Text("Default position (free-floating mode)")
                    .font(.system(size: 12, weight: .medium))
                Picker("", selection: $defaultPositionRaw) {
                    ForEach(PanelCorner.allCases) { corner in
                        Text(corner.label).tag(corner.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 200)
                Text("Where the panel snaps to when its position is reset.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Multi-session toggle
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Notify when multiple sessions are active", isOn: $notifyOnMultiSession)
                Text("Off = only long turns trigger notifications.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Reset position") { onResetPosition() }
                Spacer()
                Button("Quit Claude Notch", role: .destructive) { onQuit() }
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            // Hydrate the text mirror from the persisted value the first
            // time the view appears (or after a re-open).
            thresholdInput = String(Int(thresholdSeconds))
        }
        .onDisappear {
            commitThreshold()
        }
    }

    /// Coerce the typed value into the persisted Double, ignoring junk.
    private func commitThreshold() {
        let trimmed = thresholdInput.trimmingCharacters(in: .whitespaces)
        if let parsed = Double(trimmed), parsed >= 5, parsed <= 3600 {
            thresholdSeconds = parsed
            thresholdInput = String(Int(parsed))
        } else {
            // Roll back the input to the last persisted valid value.
            thresholdInput = String(Int(thresholdSeconds))
        }
    }
}
