import SwiftUI

/// The spacing steps, widths and corner radius every screen uses, so screens agree with each other.
/// Views pick from these instead of typing their own numbers.
enum Metrics {
    static let tight: CGFloat = 4
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let regular: CGFloat = 16
    static let large: CGFloat = 24
    static let extraLarge: CGFloat = 40

    /// The widest a column of notes or transcript gets: about 80 characters a line at the body size.
    static let readingWidth: CGFloat = 720
    static let cornerRadius: CGFloat = 8
}

// The app's own colour is `Color.brand`, the blue #2774AE, the same in light and dark mode. Xcode
// makes that name from the "Brand" colour in the asset catalogue; `MyApp` sets it as the tint.

// Backgrounds, also from the asset catalogue, each with a near-black dark-mode version (darker than the
// system's own dark grey): `Color.canvas` behind content, `Color.sidebarSurface` behind the sidebar, and
// `Color.panel` for boxes that sit on the canvas.

extension View {
    /// Puts the app's own background behind a list or form in place of the system's.
    func canvasBackground() -> some View {
        scrollContentBackground(.hidden).background(Color.canvas)
    }

    /// The whole window's background, including behind the toolbar.
    @ViewBuilder func windowCanvas() -> some View {
        #if os(macOS)
        containerBackground(Color.canvas, for: .window)
        #else
        background(Color.canvas)
        #endif
    }
}

extension View {
    /// Lightens (or in light mode darkens) the view a little while the pointer is over it, so it is
    /// clear what a click will hit. Does nothing while the view is disabled.
    func hoverHighlight(_ shape: some Shape = .rect(cornerRadius: Metrics.cornerRadius)) -> some View {
        modifier(HoverHighlight(shape: shape))
    }

    /// The hover highlight for a sidebar row, drawn as the row's background so it lines up with the
    /// selection highlight whatever the row's indent.
    func sidebarRowHover() -> some View {
        modifier(SidebarRowHover())
    }
}

private struct SidebarRowHover: ViewModifier {
    @State private var isHovered = false
    @Environment(\.showsHoverForPreview) private var showsHoverForPreview

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onHover { isHovered = $0 }
            .listRowBackground(
                RoundedRectangle(cornerRadius: Metrics.cornerRadius - 2)
                    .fill(.primary.opacity(isHovered || showsHoverForPreview ? 0.08 : 0))
                    .padding(.horizontal, Metrics.small + 2)
                    .animation(.easeOut(duration: 0.12), value: isHovered)
            )
    }
}

extension EnvironmentValues {
    /// Shows every hover highlight as if the pointer were over it. Only for drawing screens in tests and
    /// previews, where there is no pointer.
    @Entry var showsHoverForPreview = false
}

private struct HoverHighlight<S: Shape>: ViewModifier {
    let shape: S
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.showsHoverForPreview) private var showsHoverForPreview

    func body(content: Content) -> some View {
        content
            // An overlay, not a background: system buttons paint their own fill over a background.
            .overlay {
                shape
                    .fill(.primary.opacity((isHovered || showsHoverForPreview) && isEnabled ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

/// A message that sits above the content it is about: something to know, a warning, or a failure.
/// The text stays in the normal text colour on a tinted panel, so it is readable in light and dark.
struct Notice: View {
    enum Kind {
        case info, warning, failure

        var symbol: String {
            switch self {
            case .info: "info.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            }
        }

        var color: Color {
            switch self {
            case .info: .secondary
            case .warning: .orange
            case .failure: .red
            }
        }

        var spokenName: String {
            switch self {
            case .info: "Note"
            case .warning: "Warning"
            case .failure: "Error"
            }
        }
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.small) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .accessibilityLabel(kind.spokenName)
            Text(text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .padding(Metrics.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.12), in: .rect(cornerRadius: Metrics.cornerRadius))
    }
}

/// An empty screen: what is missing and, when there is one, the way to fill it. Used wherever a tab or
/// list has nothing to show, so they all look alike.
struct EmptyState<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Metrics.small) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            actions
                .padding(.top, Metrics.small)
        }
        .frame(maxWidth: 420)
        .padding(Metrics.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyState where Actions == EmptyView {
    init(_ title: String, _ message: String) {
        self.init(title: title, message: message) { EmptyView() }
    }
}
