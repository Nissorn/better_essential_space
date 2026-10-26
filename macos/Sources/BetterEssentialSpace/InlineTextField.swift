import AppKit
import SwiftUI

/// The editable text blocks of a Record's detail page.
enum EditableField: Hashable {
    case title
    case summary
    case topicTitle(String)
    case topicContent(String)
}

/// A block of detail-page text that is its own editor: it reads as plain text
/// until clicked, then edits in place. Commits on blur or after a typing
/// pause; Escape restores the value it had when focus arrived.
struct InlineTextField: View {
    let value: String
    let placeholder: String
    let font: Font
    var color: Color = ND.textPrimary
    var lineSpacing: CGFloat = 0
    let field: EditableField
    let focus: FocusState<EditableField?>.Binding
    /// Return submits (moves focus here) instead of inserting a newline.
    var submitFocus: EditableField?
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var valueAtFocus = ""
    @State private var hovering = false

    private static let idleCommitDelay: Duration = .milliseconds(800)

    private var isFocused: Bool { focus.wrappedValue == field }

    var body: some View {
        TextField(placeholder, text: text, axis: .vertical)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(font)
            .foregroundStyle(color)
            .lineSpacing(lineSpacing)
            .focused(focus, equals: field)
            .onSubmit {
                if let submitFocus { focus.wrappedValue = submitFocus }
            }
            // A vertical TextField on macOS swallows Return instead of breaking
            // the line; multi-line blocks insert the newline themselves.
            .onKeyPress(.return) {
                guard submitFocus == nil else { return .ignored }
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                return .handled
            }
            .onExitCommand(perform: revert)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(ND.textPrimary.opacity(isFocused ? 0.05 : hovering ? 0.035 : 0))
            )
            .onHover { hovering = $0 }
            .padding(.horizontal, -6)
            .padding(.vertical, -3)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onChange(of: isFocused) { _, focused in
                if focused {
                    draft = value
                    valueAtFocus = value
                } else {
                    commitIfChanged()
                }
            }
            .task(id: draft) {
                guard isFocused else { return }
                try? await Task.sleep(for: Self.idleCommitDelay)
                guard !Task.isCancelled, isFocused else { return }
                commitIfChanged()
            }
            .onDisappear {
                if isFocused { commitIfChanged() }
            }
    }

    /// Unfocused, the field shows the model's value, so a commit the model
    /// trims or rejects reads back exactly as stored. Writes after focus left
    /// are the field echoing that value back and must not clobber the draft
    /// before the blur commit reads it.
    private var text: Binding<String> {
        Binding(
            get: { isFocused ? draft : value },
            set: { if isFocused { draft = $0 } }
        )
    }

    private func commitIfChanged() {
        if draft != value { onCommit(draft) }
    }

    private func revert() {
        draft = valueAtFocus
        if value != valueAtFocus { onCommit(valueAtFocus) }
        focus.wrappedValue = nil
    }
}
