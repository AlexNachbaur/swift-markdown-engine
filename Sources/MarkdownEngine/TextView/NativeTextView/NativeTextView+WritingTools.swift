//
//  NativeTextView+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 18.10.26.
//
//  Two macOS 27 inline-rewrite bugs, both in NSTextView's own (undeclared)
//  NSWritingToolsCoordinator delegate methods, so each override calls
//  NSTextView's IMP around a fix. With paragraph spacing a plain NSTextView
//  shows them too.
//

import AppKit
import ObjectiveC

extension NativeTextView {
    /// The rewrite animates from snapshots: the viewport before the edit, then the
    /// text below the new text. AppKit takes them from the viewport's line views
    /// before it has moved and drawn them, so the rewritten paragraphs are missing
    /// and the text below lands one rewrite-height off. Committing first fixes both.
    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:requestsPreviewForRect:inContext:completion:)
    func writingToolsCoordinatorSnapshot(_ coordinator: NSWritingToolsCoordinator, for rect: NSRect,
                                         in context: NSWritingToolsCoordinator.Context,
                                         completion: @escaping (NSTextPreview?) -> Void) {
        let selector = NSSelectorFromString("writingToolsCoordinator:requestsPreviewForRect:inContext:completion:")
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return completion(nil) }
        CATransaction.flush()
        typealias Snapshot = @convention(c) (NSTextView, Selector, NSWritingToolsCoordinator, NSRect,
                                             NSWritingToolsCoordinator.Context,
                                             @escaping @convention(block) (NSTextPreview?) -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Snapshot.self)(self, selector, coordinator, rect, context, completion)
    }

    /// `.translate` slides that second snapshot into place, and the delegate has to
    /// hide the text "between the insertion point and the end of your text storage"
    /// meanwhile (NSWritingToolsCoordinator.h). NSTextView is handed an empty range
    /// and hides nothing, so the real text shows under the sliding snapshot.
    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:prepareForTextAnimation:forRange:inContext:completion:)
    func writingToolsCoordinatorPrepare(_ coordinator: NSWritingToolsCoordinator,
                                        for animation: NSWritingToolsCoordinator.TextAnimation, range: NSRange,
                                        in context: NSWritingToolsCoordinator.Context, completion: @escaping () -> Void) {
        if animation == .translate { hideWritingToolsRemainder(from: range.location) }
        callTextAnimationSuper("writingToolsCoordinator:prepareForTextAnimation:forRange:inContext:completion:",
                               coordinator, animation, range, context, completion)
    }

    @available(macOS 15.2, *)
    @objc(writingToolsCoordinator:finishTextAnimation:forRange:inContext:completion:)
    func writingToolsCoordinatorFinish(_ coordinator: NSWritingToolsCoordinator,
                                       for animation: NSWritingToolsCoordinator.TextAnimation, range: NSRange,
                                       in context: NSWritingToolsCoordinator.Context, completion: @escaping () -> Void) {
        if animation == .translate { showWritingToolsRemainder() }
        callTextAnimationSuper("writingToolsCoordinator:finishTextAnimation:forRange:inContext:completion:",
                               coordinator, animation, range, context, completion)
    }

    @available(macOS 15.2, *)
    private func callTextAnimationSuper(_ name: String, _ coordinator: NSWritingToolsCoordinator,
                                        _ animation: NSWritingToolsCoordinator.TextAnimation, _ range: NSRange,
                                        _ context: NSWritingToolsCoordinator.Context, _ completion: @escaping () -> Void) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(NSTextView.self, selector) else { return completion() }
        typealias Animation = @convention(c) (NSTextView, Selector, NSWritingToolsCoordinator, NSWritingToolsCoordinator.TextAnimation,
                                              NSRange, NSWritingToolsCoordinator.Context, @escaping @convention(block) () -> Void) -> Void
        unsafeBitCast(method_getImplementation(method), to: Animation.self)(self, selector, coordinator, animation, range, context, completion)
    }

    private func hideWritingToolsRemainder(from location: Int) {
        showWritingToolsRemainder()
        guard let tlm = textLayoutManager, let content = tlm.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: location),
              let remainder = NSTextRange(location: start, end: content.documentRange.endLocation),
              !remainder.isEmpty else { return }
        tlm.addRenderingAttribute(.foregroundColor, value: NSColor.clear, for: remainder)
        writingToolsHiddenRemainder = remainder
        redrawLineViews()
    }

    private func showWritingToolsRemainder() {
        guard let remainder = writingToolsHiddenRemainder, let tlm = textLayoutManager else { return }
        writingToolsHiddenRemainder = nil
        let end = tlm.textContentManager?.documentRange.endLocation ?? remainder.endLocation
        tlm.removeRenderingAttribute(.foregroundColor, for: NSTextRange(location: remainder.location, end: end) ?? remainder)
        redrawLineViews()
    }

    /// A rendering-attribute change alone left the line views as drawn in Nodes
    /// (measured on 27.0.1): the "hidden" text stayed on screen.
    private func redrawLineViews() {
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        redraw(self)
    }
}
