//
//  NativeTextView+HTMLBlocks.swift
//  MarkdownEngine
//
//  Hosts the views an `HTMLBlockRenderer` makes for raw HTML blocks, over the
//  space `styleHTMLBlocks` reserves for them. The pattern is the wide-table
//  overlay's: after a restyle, walk the storage for tagged anchors and create,
//  move or hide one subview per anchor.
//
//  A view's content lays out asynchronously, so its height arrives later:
//  the view reports it, the height is recorded on the `LayoutBridge` (which
//  the styler reads synchronously), and only that block is restyled. Styling
//  never waits on a view.
//

import AppKit

// MARK: - Host view

/// Holds one renderer view at the text column's width, and routes events so
/// the block behaves like the rest of the text: in edit mode a click anywhere
/// on it puts the caret into the block (revealing its source); read-only, the
/// content gets its clicks (links, text selection). Scrolling always moves
/// the document.
final class HTMLBlockHostView: NSView {
    let key: String
    /// The block's HTML, which keys its reported height.
    let html: String
    /// Document index of the block's anchor; a click in edit mode moves the caret here.
    var anchorTextLocation: Int
    weak var ownerTextView: NativeTextView?
    private(set) var content: NSView?
    /// What the content was last drawn with; a change calls the renderer's `update`.
    var drawnWith: HTMLBlockDrawingState
    /// The reconcile generation in which this block was last rendered.
    var lastSeenGeneration: Int

    init(key: String, html: String, anchorLocation: Int, ownerTextView: NativeTextView, drawnWith: HTMLBlockDrawingState, generation: Int) {
        self.key = key
        self.html = html
        self.anchorTextLocation = anchorLocation
        self.ownerTextView = ownerTextView
        self.drawnWith = drawnWith
        self.lastSeenGeneration = generation
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var isFlipped: Bool { true }

    func setContent(_ view: NSView) {
        content?.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        content = view
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hidden while the caret is in the block (or after it was edited away):
        // clicks belong to the source text under it.
        guard !isHidden else { return nil }
        guard let owner = ownerTextView, owner.isEditable else { return super.hitTest(point) }
        // `point` is in the superview's coordinates.
        return frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = ownerTextView else { return super.mouseDown(with: event) }
        let length = (textView.string as NSString).length
        guard anchorTextLocation >= 0, anchorTextLocation <= length else { return super.mouseDown(with: event) }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: anchorTextLocation, length: 0))
    }

    override func scrollWheel(with event: NSEvent) {
        if let scrollView = ownerTextView?.enclosingScrollView {
            scrollView.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

/// The body font and theme a block's view was drawn with. Theme colors are
/// compared as objects, so a dynamic system color compares equal to itself.
struct HTMLBlockDrawingState: Equatable {
    let fontName: String
    let fontSize: CGFloat
    let themeColors: [NSColor]

    init(fontName: String, fontSize: CGFloat, theme: MarkdownEditorTheme) {
        self.fontName = fontName
        self.fontSize = fontSize
        self.themeColors = Mirror(reflecting: theme).children.compactMap { $0.value as? NSColor }
    }
}

// MARK: - Renderer changes

extension MarkdownEditorServices {
    /// Changes when the hosted views must be made again: the renderer was
    /// switched on or off, or reports different drawing resources.
    var htmlBlockFingerprint: AnyHashable {
        [AnyHashable(htmlBlocks.isEnabled), htmlBlocks.fingerprint()]
    }
}

// MARK: - Reconcile

extension NativeTextView {

    /// Hidden views unseen for this many reconciles are dropped. Reconciles run
    /// per restyle, so a view survives the caret passing through its block.
    private static let htmlBlockViewRetention = 32

    /// Walk storage; create / position / hide views to match the rendered
    /// HTML-block anchors.
    func updateHTMLBlockViews() {
        let renderer = configuration.services.htmlBlocks
        guard renderer.isEnabled,
              let storage = textStorage,
              let bridge = layoutBridge,
              let container = bridge.firstTextContainer,
              let tlm = textLayoutManager else {
            removeAllHTMLBlockViews()
            return
        }

        var anchors: [(range: NSRange, anchor: HTMLBlockAnchor)] = []
        storage.enumerateAttribute(.htmlBlockAnchor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let anchor = value as? HTMLBlockAnchor { anchors.append((range, anchor)) }
        }
        htmlBlockReconcileGeneration &+= 1
        let generation = htmlBlockReconcileGeneration
        defer { pruneHTMLBlockHeights(keeping: anchors.map(\.anchor.html)) }
        guard let last = anchors.last else {
            hideHTMLBlockViews(unseenSince: generation)
            return
        }

        // Settle layout first, through the last block only: stale fragments
        // would put views at old Ys, and text after it doesn't move them.
        let documentRange = tlm.documentRange
        if let lastEnd = tlm.textContentManager?.location(documentRange.location, offsetBy: NSMaxRange(last.range)),
           let settled = NSTextRange(location: documentRange.location, end: lastEnd) {
            tlm.ensureLayout(for: settled)
        } else {
            tlm.ensureLayout(for: documentRange)
        }
        let width = max(container.size.width - container.lineFragmentPadding * 2, 1)
        var occurrences: [String: Int] = [:]
        for (range, anchor) in anchors {
            let occurrence = occurrences[anchor.html, default: 0]
            occurrences[anchor.html] = occurrence + 1
            let key = "\(occurrence)#\(anchor.html)"

            let anchorRect = bridge.boundingRect(forCharacterRange: NSRange(location: range.location, length: 1), in: container)
            guard !anchorRect.isEmpty else { continue }
            let height = bridge.htmlBlockHeights[anchor.html] ?? anchorRect.height
            let frame = NSRect(
                x: textContainerOrigin.x + container.lineFragmentPadding,
                y: textContainerOrigin.y + anchorRect.minY,
                width: width,
                height: height
            )
            let content = HTMLBlockContent(
                html: anchor.html,
                fontName: anchor.fontName,
                fontSize: anchor.fontSize,
                theme: configuration.theme
            )
            let drawingState = HTMLBlockDrawingState(
                fontName: anchor.fontName,
                fontSize: anchor.fontSize,
                theme: configuration.theme
            )

            if let host = htmlBlockViews[key] {
                host.lastSeenGeneration = generation
                host.anchorTextLocation = range.location
                host.isHidden = false
                if !host.frame.equalTo(frame) {
                    setNeedsDisplay(host.frame)
                    host.frame = frame
                    setNeedsDisplay(frame)
                }
                if host.drawnWith != drawingState, let view = host.content {
                    host.drawnWith = drawingState
                    renderer.update(view, for: content)
                }
            } else {
                let host = HTMLBlockHostView(
                    key: key,
                    html: anchor.html,
                    anchorLocation: range.location,
                    ownerTextView: self,
                    drawnWith: drawingState,
                    generation: generation
                )
                host.frame = frame
                let html = anchor.html
                let view = renderer.makeView(for: content) { [weak self] height in
                    self?.htmlBlock(html, didReportHeight: height)
                }
                host.setContent(view)
                addSubview(host)
                htmlBlockViews[key] = host
            }
        }
        hideHTMLBlockViews(unseenSince: generation)
    }

    /// Hides views whose block is not rendered right now (the caret is in it,
    /// or it was edited away), and drops the ones unseen for a while.
    private func hideHTMLBlockViews(unseenSince generation: Int) {
        for (key, host) in htmlBlockViews where host.lastSeenGeneration != generation {
            if !host.isHidden {
                host.isHidden = true
                setNeedsDisplay(host.frame)
            }
            if generation &- host.lastSeenGeneration > Self.htmlBlockViewRetention {
                host.removeFromSuperview()
                htmlBlockViews.removeValue(forKey: key)
            }
        }
    }

    /// Forgets reported heights for HTML no longer in the document or held by
    /// a retained view, so a block edited many times leaves no trail of them.
    private func pruneHTMLBlockHeights(keeping rendered: [String]) {
        guard let bridge = layoutBridge, !bridge.htmlBlockHeights.isEmpty else { return }
        let live = Set(rendered).union(htmlBlockViews.values.map(\.html))
        for html in bridge.htmlBlockHeights.keys where !live.contains(html) {
            bridge.htmlBlockHeights.removeValue(forKey: html)
        }
    }

    /// Drop every hosted view synchronously (document switch, renderer off).
    func removeAllHTMLBlockViews() {
        for (_, host) in htmlBlockViews { host.removeFromSuperview() }
        htmlBlockViews.removeAll()
        htmlBlocksAwaitingRestyle.removeAll()
    }

    // MARK: Reported heights

    /// Records a block's new content height and restyles that block once per
    /// run-loop turn, however many views report in it.
    func htmlBlock(_ html: String, didReportHeight reported: CGFloat) {
        guard let bridge = layoutBridge, reported.isFinite, reported > 0 else { return }
        let height = ceil(reported)
        if let current = bridge.htmlBlockHeights[html], abs(current - height) < 0.5 { return }
        bridge.htmlBlockHeights[html] = height
        let alreadyScheduled = !htmlBlocksAwaitingRestyle.isEmpty
        htmlBlocksAwaitingRestyle.insert(html)
        guard !alreadyScheduled else { return }
        RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated {
                self?.restyleHTMLBlocksAwaitingHeight()
            }
        }
    }

    private func restyleHTMLBlocksAwaitingHeight() {
        let pending = htmlBlocksAwaitingRestyle
        htmlBlocksAwaitingRestyle.removeAll()
        guard !pending.isEmpty, let coordinator = delegate as? NativeTextViewCoordinator else { return }
        let text = string
        let ns = text as NSString
        let parsed = coordinator.parsedDocument(for: text)
        let paragraphs = parsed.classified.htmlBlock
            .filter { pending.contains(ns.substring(with: $0.token.range)) }
            .map { ns.paragraphRange(for: $0.token.range) }
        guard !paragraphs.isEmpty else { return }
        coordinator.restyleParagraphs(paragraphs, in: self)
        updateHTMLBlockViews()
    }
}
