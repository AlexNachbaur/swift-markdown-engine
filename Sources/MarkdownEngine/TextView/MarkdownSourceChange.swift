//
//  MarkdownSourceChange.swift
//  MarkdownEngine
//

import Foundation

/// One replacement in the source text — the storage form the `text` binding
/// carries, with `[[Name|<id>]]` wiki links — in UTF-16 coordinates.
public struct MarkdownSourceEdit: Equatable, Sendable {
    public let range: NSRange
    public let replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Everything that changed in the source text since the previous change.
///
/// Unlike ``MarkdownTextMutation``, which leaves out edits it can't describe as
/// one native edit, the changes of a document form a complete record: applying
/// each in turn to the text the editor started with always gives
/// ``MarkdownEditorHandle/sourceText``. An input-method composition and a Writing
/// Tools session each arrive as one change when they finish.
public struct MarkdownSourceChange: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// Made in the text view: typing, smart input, paste, formatting, find and
        /// replace, undo and redo, Writing Tools.
        case editor
        /// The `text` binding was given a new value for the same document.
        case binding
    }

    /// Non-overlapping and last first, so every range addresses the text before
    /// this change, whether the edits are applied in order or looked at together.
    public let edits: [MarkdownSourceEdit]
    public let origin: Origin

    public init(edits: [MarkdownSourceEdit], origin: Origin) {
        self.edits = edits
        self.origin = origin
    }
}
