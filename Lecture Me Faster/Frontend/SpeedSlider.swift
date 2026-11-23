import SwiftUI

/// Faster ↔ Most accurate: one control for the settings that trade speed (and cost) for accuracy. See
/// `AppSettings.SpeedPreset` for what each position sets and why slide finding isn't one of them.
struct SpeedSlider: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.small) {
            HStack(spacing: Metrics.small) {
                Text("Faster").foregroundStyle(.secondary)
                Slider(value: position, in: 0...2, step: 1) { Text("Speed") }
                    .labelsHidden()
                    .accessibilityValue(settings.speedPreset?.label ?? "Custom")
                Text("Most accurate").foregroundStyle(.secondary)
            }
            Text(settings.speedPreset.map { "\($0.label): \($0.summary)" } ?? "Custom: you've changed these settings under Advanced. Move the slider to use a preset again.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Custom settings show at Balanced until the slider is moved.
    private var position: Binding<Double> {
        Binding {
            Double((settings.speedPreset ?? .balanced).rawValue)
        } set: { value in
            if let preset = AppSettings.SpeedPreset(rawValue: Int(value.rounded())) { settings.apply(preset) }
        }
    }
}
