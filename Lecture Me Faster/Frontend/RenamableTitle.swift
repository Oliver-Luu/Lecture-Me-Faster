import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Shows `title` in the toolbar as a button. Clicking it turns it into a text field with the whole
    /// name selected: Return or clicking elsewhere saves, Esc cancels.
    ///
    /// SwiftUI's own `navigationTitle(Binding)` rename is not used: it is reported not to work on macOS
    /// and on iOS it opens a menu first instead of going straight to editing.
    func renamableTitle(_ title: String, onRename: @escaping (String) -> Void) -> some View {
        modifier(RenamableTitleModifier(title: title, onRename: onRename))
    }
}

private struct RenamableTitleModifier: ViewModifier {
    let title: String
    let onRename: (String) -> Void

    func body(content: Content) -> some View {
        content
            // Still set, so the window keeps its name in the Window menu and Mission Control.
            .navigationTitle(title)
            #if os(macOS)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    RenamableTitle(title: title, onRename: onRename)
                }
            }
            #else
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    RenamableTitle(title: title, onRename: onRename)
                }
            }
            #endif
    }
}

struct RenamableTitle: View {
    let title: String
    let onRename: (String) -> Void

    @State private var isEditing = false
    @State private var draft = ""
    @State private var selection: TextSelection?
    @State private var isCancelled = false
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            #if os(macOS)
            // SwiftUI focus doesn't reach text fields in the macOS toolbar, so use AppKit's directly.
            ToolbarTitleField(text: $draft, onCommit: finish, onCancel: cancel)
                .frame(width: 320)
            #else
            TextField("Lecture name", text: $draft, selection: $selection)
                .textFieldStyle(.roundedBorder)
                .font(.headline)
                .frame(minWidth: 200, idealWidth: 320, maxWidth: 420)
                .focused($isFocused)
                .onSubmit(finish)
                .onChange(of: isFocused) { _, focused in
                    if !focused { finish() }
                }
                .task {
                    // A toolbar item isn't ready to take focus during onAppear, so wait a moment.
                    try? await Task.sleep(for: .milliseconds(50))
                    isFocused = true
                    selection = TextSelection(range: draft.startIndex..<draft.endIndex)
                }
            #endif
        } else {
            Button(action: beginEditing) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // Without this the toolbar's bubble hugs the text with ~4 pt each side.
                    .padding(.horizontal, 8)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Click to rename")
            .accessibilityLabel("Lecture name: \(title)")
            .accessibilityHint("Rename the lecture")
        }
    }

    private func beginEditing() {
        draft = title
        isCancelled = false
        isEditing = true
    }

    private func cancel() {
        isCancelled = true
        finish()
    }

    /// Runs once per edit, whichever of Return, Esc, or losing focus comes first.
    private func finish() {
        guard isEditing else { return }
        isEditing = false
        if let name = Self.newName(from: draft, replacing: title, cancelled: isCancelled) {
            onRename(name)
        }
    }

    /// The name to save when editing ends, or nil to leave the lecture as it is: after Esc, for an empty
    /// name, or when nothing changed.
    nonisolated static func newName(from draft: String, replacing current: String, cancelled: Bool) -> String? {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return cancelled || name.isEmpty || name == current ? nil : name
    }
}

#if os(macOS)
/// An AppKit text field for the toolbar that takes keyboard focus and selects all its text as soon as it
/// is placed in the window. Return commits, Esc cancels, and clicking elsewhere commits.
private struct ToolbarTitleField: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = SelfFocusingTextField(string: text)
        field.font = .preferredFont(forTextStyle: .headline)
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("Lecture name")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ToolbarTitleField

        init(parent: ToolbarTitleField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField {
                parent.text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                parent.onCommit()
                return true
            default:
                return false
            }
        }

        /// Focus moved elsewhere (a click outside the field).
        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onCommit()
        }
    }
}

private final class SelfFocusingTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Wait for the toolbar to finish laying out before taking focus.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}
#endif
