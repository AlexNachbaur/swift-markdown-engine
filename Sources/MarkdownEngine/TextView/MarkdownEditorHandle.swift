//
//  MarkdownEditorHandle.swift
//  MarkdownEngine
//

import AppKit

/// An embedder's reference to a mounted editor.
///
/// Create one, keep it as long as the host view, and pass it to one
/// ``NativeTextViewWrapper``. It refers to the editor only while that is mounted,
/// and to the new one after a remount.
@MainActor
public final class MarkdownEditorHandle {
    private(set) weak var coordinator: NativeTextViewCoordinator?

    /// A handle that refers to no editor yet.
    public init() {}

    /// The editor's text view, or `nil` while no editor is mounted.
    public var textView: NSTextView? { coordinator?.textView }

    /// The source text as of the last ``MarkdownSourceChange``, or `nil` while no
    /// editor is mounted. The `text` binding follows it a moment later.
    public var sourceText: String? { coordinator?.sourceEdits.source }

    /// The source range of a range in the text view. Both are in UTF-16 units and
    /// differ after and inside `[[Name|<id>]]` links, which the text view shows as
    /// `[[Name]]`. `nil` while no editor is mounted, while a composition or Writing
    /// Tools session is unfinished, or if the range is out of bounds.
    public func sourceRange(forDisplayRange range: NSRange) -> NSRange? {
        guard let map = coordinator?.settledWikiLinkMap,
              let length = coordinator?.textView?.textStorage?.length,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.length <= length, range.location <= length - range.length else { return nil }
        return map.sourceRange(forDisplayRange: range)
    }

    /// The text view's range for a source range; the inverse of
    /// ``sourceRange(forDisplayRange:)``. A position inside a link's hidden
    /// `|<id>` lands at the end of its name.
    public func displayRange(forSourceRange range: NSRange) -> NSRange? {
        guard let map = coordinator?.settledWikiLinkMap,
              let length = coordinator?.sourceEdits.source?.utf16.count,
              range.location != NSNotFound, range.location >= 0, range.length >= 0,
              range.length <= length, range.location <= length - range.length else { return nil }
        return map.displayRange(forSourceRange: range)
    }

    func attach(to coordinator: NativeTextViewCoordinator) {
        guard self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
    }

    /// Only if it still refers to `coordinator`: a remount can attach the new
    /// editor before the old one is dismantled.
    func detach(from coordinator: NativeTextViewCoordinator) {
        if self.coordinator === coordinator { self.coordinator = nil }
    }
}
