//
//  NativeTextView+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.10.26.
//

import AppKit

extension NativeTextView {
    /// An inline Writing Tools rewrite slides a snapshot of the text below it into
    /// place. macOS 27 takes that snapshot from the viewport's line views before
    /// AppKit has moved them, so with paragraph spacing (a plain NSTextView too) it
    /// shows the old line positions and lands one rewrite-height off: doubled words.
    /// Committing here moves and draws them first.
    override func didChangeText() {
        super.didChangeText()
        guard #available(macOS 15.0, *), isWritingToolsActive else { return }
        layoutSubtreeIfNeeded()
        CATransaction.flush()
    }
}
