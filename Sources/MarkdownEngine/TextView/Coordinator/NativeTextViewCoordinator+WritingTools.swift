//
//  NativeTextViewCoordinator+WritingTools.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  macOS 15+ Writing Tools integration: pauses styling during the session, re-syncs results on end, fixes child window position, and recovers from Apple's stale-accept-action bug after mid-session Cmd+Z.
//

import AppKit

extension NativeTextViewCoordinator {
    @available(macOS 15.0, *)
    public func textViewWritingToolsWillBegin(_ textView: NSTextView) {
        let sel = textView.selectedRange()
        isWritingToolsActive = true
        wtStartDocumentId = documentId
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        wtInitialSelectionRange = sel.length > 0 ? sel : nil
        wtDetectedMode = .unknown
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil
        observeUndoNotifications(for: textView.undoManager)
        scheduleChildWindowFix(textView: textView, attemptsRemaining: 20)
    }

    @available(macOS 15.0, *)
    public func textViewWritingToolsDidEnd(_ textView: NSTextView) {
        (textView as? NativeTextView)?.endWritingToolsHide()
        guard isWritingToolsActive else { return }
        isWritingToolsActive = false
        wtChildWindow = nil
        wtInitialChildOrigin = nil
        stopObservingUndoNotifications()

        // Doc switched mid-session, or a switch waits for this end: the binding
        // already belongs to the new node, so the WT result is discarded.
        if deferredNodeSwitch != nil || (wtStartDocumentId != nil && wtStartDocumentId != documentId) {
            wtStartDocumentId = nil
            return
        }
        wtStartDocumentId = nil

        // Cmd+Z mid-session: Apple's stale accept-action corrupts text + contaminates attrs with 0.1pt marker font; the post-undo snapshot is the authoritative state.
        let sourceText: String
        let undoDuringSession: Bool
        if wtUndoneDuringSession, let snapshot = wtPostUndoSnapshot {
            sourceText = snapshot
            undoDuringSession = true
        } else {
            sourceText = textView.string
            undoDuringSession = false
        }
        wtUndoneDuringSession = false
        wtPostUndoSnapshot = nil

        let storageState = WikiLinkService.makeStorageState(
            from: sourceText,
            existingMetadata: wikiLinkMetadata,
            textStorage: textView.textStorage
        )
        wikiLinkMetadata = storageState.metadata
        let storage = storageState.storage

        // Binding is already equal to `storage` after undo so SwiftUI won't re-render — rebuild the textView directly.
        if undoDuringSession {
            rebuildTextStorageAndStyle(textView, from: storage)
        }
        // Don't pre-set `lastSyncedText` — leaving it stale lets updateNSView do its
        // normal rebuild (restyle + re-measure) so the accepted WT result stays visible.
        let target = documentId
        DispatchQueue.main.async { [self] in
            guard bindingFollows(target) else { return }
            text = storage
        }
    }

    /// Writing Tools rewrite prose only: code, formulas, links, embeds and tables come
    /// back as written (the zones spell checking skips too).
    @available(macOS 15.0, *)
    public func textView(_ textView: NSTextView,
                         writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        parsedDocument(for: textView.string).tokens.compactMap { token in
            switch token.kind {
            case .codeBlock, .inlineCode, .inlineLatex, .blockLatex, .link, .wikiLink, .imageEmbed, .imageLink, .table:
                let range = NSIntersectionRange(token.range, enclosingRange)
                return range.length > 0 ? NSValue(range: range) : nil
            default:
                return nil
            }
        }
    }

    // MARK: - Child window (Done/Original panel) position fix

    private func scheduleChildWindowFix(textView: NSTextView, attemptsRemaining: Int) {
        guard attemptsRemaining > 0, isWritingToolsActive else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isWritingToolsActive else { return }
            self.captureChildWindowIfNeeded(textView: textView)
            if self.wtChildWindow == nil {
                self.scheduleChildWindowFix(textView: textView, attemptsRemaining: attemptsRemaining - 1)
            }
        }
    }

    private func captureChildWindowIfNeeded(textView: NSTextView) {
        guard wtChildWindow == nil,
              let mainWindow = textView.window,
              let childWin = mainWindow.childWindows?.first(where: { $0.isVisible }) else { return }
        wtChildWindow = childWin
        wtInitialChildOrigin = childWin.frame.origin
    }

    // MARK: - Undo observer (captures post-undo snapshot for recovery)

    private func observeUndoNotifications(for undoManager: UndoManager?) {
        stopObservingUndoNotifications()
        guard let um = undoManager else { return }
        let center = NotificationCenter.default
        wtUndoObserverTokens = [
            center.addObserver(forName: .NSUndoManagerDidUndoChange, object: um, queue: .main) { [weak self] _ in
                guard let self, let tv = self.textView, self.isWritingToolsActive else { return }
                self.wtUndoneDuringSession = true
                self.wtPostUndoSnapshot = tv.string
            }
        ]
    }

    private func stopObservingUndoNotifications() {
        wtUndoObserverTokens.forEach(NotificationCenter.default.removeObserver(_:))
        wtUndoObserverTokens.removeAll()
    }

    func fixWritingToolsChildWindowIfNeeded(textView: NSTextView) {
        guard let childWin = wtChildWindow,
              let correctOrigin = wtInitialChildOrigin else { return }

        let frame = childWin.frame
        let needsFix = abs(frame.origin.x - correctOrigin.x) > 0.5 || abs(frame.origin.y - correctOrigin.y) > 0.5
        if needsFix {
            var fixed = frame
            fixed.origin = correctOrigin
            childWin.setFrame(fixed, display: false)
        }
    }

    /// Stops the session (its result is dropped: the document is about to change)
    /// and replays the latest switch once the coordinator leaves `.interactiveStreaming`.
    @available(macOS 15.2, *)
    func deferNodeSwitch(until writingTools: NSWritingToolsCoordinator, replay: @escaping () -> Void) {
        deferredNodeSwitch = replay
        guard deferredNodeSwitchTimer == nil else { return }
        writingTools.stopWritingTools()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self, weak writingTools] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                if let writingTools, writingTools.state == .interactiveStreaming { return }
                let replay = self.deferredNodeSwitch
                self.cancelDeferredNodeSwitch()
                replay?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        deferredNodeSwitchTimer = timer
    }

    /// Whether text from the text view may still reach the binding. SwiftUI hands over
    /// the next document's binding before a deferred switch reaches the text view, and
    /// an async write can land after a switch.
    func bindingFollows(_ documentId: String?) -> Bool {
        deferredNodeSwitch == nil && documentId == self.documentId
    }

    func cancelDeferredNodeSwitch() {
        deferredNodeSwitchTimer?.invalidate()
        deferredNodeSwitchTimer = nil
        deferredNodeSwitch = nil
    }
}
