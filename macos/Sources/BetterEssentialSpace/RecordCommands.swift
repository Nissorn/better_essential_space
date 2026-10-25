import SwiftUI

/// The visible window's current capabilities, published to the menu bar via
/// `focusedSceneValue` so Commands can act on whatever window is frontmost.
struct RecordCommands {
    var focusSearch: () -> Void = {}
    var exportAll: (() -> Void)?
    var exportSelected: (() -> Void)?
}

struct RecordCommandsKey: FocusedValueKey {
    typealias Value = RecordCommands
}

extension FocusedValues {
    var recordCommands: RecordCommands? {
        get { self[RecordCommandsKey.self] }
        set { self[RecordCommandsKey.self] = newValue }
    }
}
