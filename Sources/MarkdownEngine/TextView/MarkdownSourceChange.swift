//
//  MarkdownSourceChange.swift
//  MarkdownEngine
//

import Foundation

/// One replacement in the source text — the storage form the `text` binding
/// carries, with `[[Name|<id>]]` wiki links — in UTF-16 coordinates.
public struct MarkdownSourceEdit: Equatable, Sendable {
    /// What is replaced, in the text before the change the edit belongs to.
    public let range: NSRange
    /// What replaces it.
    public let replacement: String

    /// An edit that puts `replacement` in place of `range`.
    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Everything that changed in the source text since the previous change.
///
/// Unlike ``MarkdownTextMutation``, which leaves out edits it can't describe as
/// one native edit, the changes form a complete record. A mirror that is emptied
/// by each ``Origin/start`` and applies every change's edits always equals
/// ``MarkdownEditorHandle/sourceText``. An input-method composition and a Writing
/// Tools session each arrive as one change when they finish. (In raw source mode
/// the binding follows a Writing Tools session step by step; this doesn't.)
public struct MarkdownSourceChange: Equatable, Sendable {
    /// What made a change.
    public enum Origin: Equatable, Sendable {
        /// The editor began with a text: it was mounted (again), switched to another
        /// `documentId`, or had no handler until now. The edits insert the whole text into an empty one.
        ///
        /// An editor that replaces another can start from a `text` the old one's
        /// last edit hasn't reached yet; that edit then follows as a `binding` change.
        /// An embedder whose mirror outlives an editor compares the two here.
        case start
        /// Made in the text view: typing, smart input, paste, formatting, find and
        /// replace, undo and redo, Writing Tools.
        case editor
        /// The `text` binding was given a new value for the same document.
        case binding
    }

    /// Non-overlapping and last first, so every range addresses the text before
    /// this change, whether the edits are applied in order or looked at together.
    public let edits: [MarkdownSourceEdit]
    /// What made the change.
    public let origin: Origin

    /// A change made of `edits`, which must be ordered as ``edits`` says.
    public init(edits: [MarkdownSourceEdit], origin: Origin) {
        self.edits = edits
        self.origin = origin
    }
}
