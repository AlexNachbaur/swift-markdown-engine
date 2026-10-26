//
//  NativeTextView+HTMLBlocks.swift
//  MarkdownEngine
//
//  Hosts the views an `HTMLBlockRenderer` makes for raw HTML blocks, over the
//  space `styleHTMLBlocks` reserves for them. The pattern is the wide-table
//  overlay's: after a restyle, and as the document scrolls, walk the storage
//  for tagged anchors and create, move, hide or release one subview per anchor.
//
//  Only blocks on or near the screen have a view; the rest keep the space
//  their last measured height reserves. A view's content lays out
//  asynchronously, so its height arrives later: the view reports it, the
//  height is recorded on the `LayoutBridge` with the column width it was
//  measured at (the styler reads it synchronously), and only that block is
//  restyled. Styling never waits on a view. Blocks with no height for the
//  current width are measured ahead of time by views placed off screen.
//

import AppKit

// MARK: - Host view

/// Holds one renderer view at the text column's width, and routes events so
/// the block behaves like the rest of the text: in edit mode a click anywhere
/// on it puts the caret into the block (revealing its source); read-only, the
/// content gets its clicks (links, text selection). Scrolling always moves
/// the document. A measuring host sits off screen and takes no events.
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
    /// Off screen, measuring a block's height ahead of scrolling.
    var isMeasuring = false
    /// Cleared when the view goes back to the renderer; reports after that are ignored.
    var isActive = true
    /// Set for a live view of a block that already has a height for this
    /// layout: while its page loads it reports passing heights (before its
    /// images arrive), and applying them would move the text and the scroller
    /// only to move them back. Its reports wait until it has settled.
    var holdsReportsUntilSettled = false
    /// The latest report held back, applied once the view has settled.
    var heldHeight: CGFloat?
    var settleTimer: Timer?
    /// When holding stops regardless, for a view that never says it settled.
    var holdDeadline = Date.distantFuture

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

    /// Takes the content out, for handing back to the renderer.
    func takeContent() -> NSView? {
        let view = content
        view?.removeFromSuperview()
        content = nil
        return view
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Hidden while the caret is in the block (or after it was edited away):
        // clicks belong to the source text under it.
        guard !isHidden, !isMeasuring else { return nil }
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

/// An off-screen view measuring one block's height for a layout. It is done
/// once its reports have settled and the renderer says it has finished
/// loading, or at a deadline if that never happens.
final class HTMLBlockMeasurement {
    let host: HTMLBlockHostView
    let layout: HTMLBlockLayout
    var settleTimer: Timer?
    var deadlineTimer: Timer?
    /// The latest height reported; recorded only when the measurement is
    /// done, so the passing heights of a loading page never move the text.
    var lastReported: CGFloat?

    init(host: HTMLBlockHostView, layout: HTMLBlockLayout) {
        self.host = host
        self.layout = layout
    }

    func invalidateTimers() {
        settleTimer?.invalidate()
        deadlineTimer?.invalidate()
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

    /// Hidden views unseen for this many reconciles are released. Reconciles
    /// run per restyle, so a view survives the caret passing through its block.
    private static let htmlBlockViewRetention = 32

    /// How many blocks are measured off screen at once.
    static let htmlBlockMeasurementLimit = 2
    /// A measurement is done once its view has reported nothing new for this long…
    static var htmlBlockMeasurementSettleDelay: TimeInterval = 0.4
    /// …or this long after it started, whichever comes first.
    static var htmlBlockMeasurementDeadline: TimeInterval = 4

    /// Where measuring views sit: far left of anything the clip view shows.
    private static let htmlBlockMeasuringOriginX: CGFloat = -100_000

    /// The part of the document whose blocks get a live view: the visible
    /// rect and a screen's height above and below it. Everything when the
    /// text view has no scroll view to say what is visible; nothing while
    /// its scroll view has no size yet (the first passes after a document
    /// opens), until scrolling or resizing reconciles again.
    private var htmlBlockLiveRect: NSRect {
        let visible = visibleRect
        guard !visible.isEmpty else { return enclosingScrollView == nil ? .infinite : .null }
        let margin = max(visible.height, 200)
        return visible.insetBy(dx: -visible.width, dy: -margin)
    }

    /// Walk storage; create / position / hide / release views to match the
    /// rendered HTML-block anchors and the part of the document on screen;
    /// start measuring blocks that need a height.
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
        let liveRect = htmlBlockLiveRect
        htmlBlockDocumentHasBlocks = !anchors.isEmpty
        defer { pruneHTMLBlockHeights(keeping: anchors.map(\.anchor.html)) }
        guard let last = anchors.last else {
            hideHTMLBlockViews(unseenSince: generation, liveRect: liveRect, renderer: renderer)
            cancelHTMLBlockMeasurements(keeping: [], renderer: renderer)
            return
        }
        observeHTMLBlockScrolling()

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
        let center = liveRect.isNull ? 0 : liveRect.midY
        var occurrences: [String: Int] = [:]
        var liveHTML: Set<String> = []
        var needsMeasuring: [(html: String, content: HTMLBlockContent, drawingState: HTMLBlockDrawingState, layout: HTMLBlockLayout, distance: CGFloat)] = []
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
            let layout = HTMLBlockLayout(width: width, fontName: anchor.fontName, fontSize: anchor.fontSize)

            guard frame.intersects(liveRect) else {
                // Far from the screen: no view, only the reserved space.
                if let host = htmlBlockViews[key] { releaseHTMLBlockHost(host, renderer: renderer) }
                if !hasHTMLBlockHeight(anchor.html, for: layout) {
                    let distance = min(abs(frame.minY - center), abs(frame.maxY - center))
                    needsMeasuring.append((anchor.html, content, drawingState, layout, distance))
                }
                continue
            }
            liveHTML.insert(anchor.html)

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
                if hasHTMLBlockHeight(anchor.html, for: layout) {
                    host.holdsReportsUntilSettled = true
                    host.holdDeadline = Date().addingTimeInterval(Self.htmlBlockMeasurementDeadline)
                }
                let html = anchor.html
                let view = renderer.makeView(for: content) { [weak self, weak host] reported in
                    guard let self, let host, host.isActive else { return }
                    self.liveHTMLBlock(host, didReport: reported)
                }
                host.setContent(view)
                addSubview(host)
                htmlBlockViews[key] = host
            }
        }
        hideHTMLBlockViews(unseenSince: generation, liveRect: liveRect, renderer: renderer)

        // A live view measures its block itself; measure the rest nearest first.
        let present = Set(anchors.map(\.anchor.html))
        cancelHTMLBlockMeasurements(keeping: present.subtracting(liveHTML), renderer: renderer)
        var queued: Set<String> = []
        for candidate in needsMeasuring.sorted(by: { $0.distance < $1.distance }) {
            guard htmlBlockMeasurements.count < Self.htmlBlockMeasurementLimit else { break }
            guard !liveHTML.contains(candidate.html), htmlBlockMeasurements[candidate.html] == nil,
                  queued.insert(candidate.html).inserted else { continue }
            startHTMLBlockMeasurement(
                candidate.html,
                content: candidate.content,
                drawingState: candidate.drawingState,
                layout: candidate.layout,
                generation: generation,
                renderer: renderer
            )
        }
    }

    /// Whether the block was measured with `layout` (its height may be 0:
    /// content that draws nothing, such as a lone `<style>`).
    private func hasHTMLBlockHeight(_ html: String, for layout: HTMLBlockLayout) -> Bool {
        guard let measured = layoutBridge?.htmlBlockMeasuredLayouts[html] else { return false }
        return measured.matches(layout)
    }

    /// Hides views whose block is not rendered right now (the caret is in it,
    /// or it was edited away), and releases the ones far from the screen, and
    /// the ones whose HTML has left the document after a while. A view whose
    /// block's source is being edited stays, however much the reader scrolls
    /// near it, so leaving the block doesn't reload it.
    private func hideHTMLBlockViews(unseenSince generation: Int, liveRect: NSRect, renderer: any HTMLBlockRenderer) {
        let text = string as NSString
        for (_, host) in htmlBlockViews where host.lastSeenGeneration != generation {
            if !host.isHidden {
                host.isHidden = true
                setNeedsDisplay(host.frame)
            }
            let farAway = !host.frame.intersects(liveRect)
            let editedAway = generation &- host.lastSeenGeneration > Self.htmlBlockViewRetention
                && text.range(of: host.html).location == NSNotFound
            if farAway || editedAway {
                releaseHTMLBlockHost(host, renderer: renderer)
            }
        }
    }

    /// A live view reported: apply it, or hold it until the view has settled.
    private func liveHTMLBlock(_ host: HTMLBlockHostView, didReport reported: CGFloat) {
        guard host.holdsReportsUntilSettled else {
            htmlBlock(host.html, didReportHeight: reported, layout: liveLayout(of: host))
            return
        }
        host.heldHeight = reported
        scheduleLiveSettleCheck(host)
    }

    private func liveLayout(of host: HTMLBlockHostView) -> HTMLBlockLayout {
        HTMLBlockLayout(width: host.frame.width, fontName: host.drawnWith.fontName, fontSize: host.drawnWith.fontSize)
    }

    private func scheduleLiveSettleCheck(_ host: HTMLBlockHostView) {
        guard host.settleTimer == nil else { return }
        host.settleTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self, weak host] timer in
            MainActor.assumeIsolated {
                guard let self, let host, host.isActive, let view = host.content else {
                    timer.invalidate()
                    return
                }
                guard self.configuration.services.htmlBlocks.hasSettled(view) || Date() >= host.holdDeadline else { return }
                timer.invalidate()
                host.settleTimer = nil
                host.holdsReportsUntilSettled = false
                if let held = host.heldHeight {
                    host.heldHeight = nil
                    self.htmlBlock(host.html, didReportHeight: held, layout: self.liveLayout(of: host))
                }
            }
        }
    }

    /// Takes a host out and gives its view back to the renderer.
    private func releaseHTMLBlockHost(_ host: HTMLBlockHostView, renderer: any HTMLBlockRenderer) {
        host.isActive = false
        host.settleTimer?.invalidate()
        host.settleTimer = nil
        if htmlBlockViews[host.key] === host { htmlBlockViews.removeValue(forKey: host.key) }
        if !host.isHidden { setNeedsDisplay(host.frame) }
        host.removeFromSuperview()
        if let view = host.takeContent() { renderer.releaseView(view) }
    }

    /// Forgets reported heights for HTML no longer in the document or held by
    /// a retained view, so a block edited many times leaves no trail of them.
    private func pruneHTMLBlockHeights(keeping rendered: [String]) {
        guard let bridge = layoutBridge, !bridge.htmlBlockHeights.isEmpty else { return }
        let live = Set(rendered)
            .union(htmlBlockViews.values.map(\.html))
            .union(htmlBlockMeasurements.keys)
        for html in bridge.htmlBlockHeights.keys where !live.contains(html) {
            bridge.htmlBlockHeights.removeValue(forKey: html)
            bridge.htmlBlockMeasuredLayouts.removeValue(forKey: html)
        }
    }

    /// Releases every hosted and measuring view synchronously (document
    /// switch, renderer change), back to the renderer configured now.
    func removeAllHTMLBlockViews() {
        let renderer = configuration.services.htmlBlocks
        for (_, host) in htmlBlockViews { releaseHTMLBlockHost(host, renderer: renderer) }
        htmlBlockViews.removeAll()
        cancelHTMLBlockMeasurements(keeping: [], renderer: renderer)
        htmlBlocksAwaitingRestyle.removeAll()
    }

    // MARK: Scrolling

    /// Reconciles as the document scrolls, so views follow the screen.
    private func observeHTMLBlockScrolling() {
        guard let clipView = enclosingScrollView?.contentView, clipView !== htmlBlockObservedClipView else { return }
        if let old = htmlBlockObservedClipView {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: old)
        }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(htmlBlockClipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )
        htmlBlockObservedClipView = clipView
    }

    @objc private func htmlBlockClipViewBoundsDidChange(_ notification: Notification) {
        guard htmlBlockDocumentHasBlocks else { return }
        scheduleHTMLBlockReconcile()
    }

    /// One reconcile per run-loop turn, however many scroll steps arrive in it.
    func scheduleHTMLBlockReconcile() {
        guard !htmlBlockReconcileScheduled else { return }
        htmlBlockReconcileScheduled = true
        RunLoop.main.perform(inModes: [.default, .eventTracking]) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.htmlBlockReconcileScheduled = false
                self.updateHTMLBlockViews()
            }
        }
    }

    // MARK: Measuring

    private func startHTMLBlockMeasurement(
        _ html: String,
        content: HTMLBlockContent,
        drawingState: HTMLBlockDrawingState,
        layout: HTMLBlockLayout,
        generation: Int,
        renderer: any HTMLBlockRenderer
    ) {
        let width = layout.width
        let host = HTMLBlockHostView(
            key: "measuring#\(html)",
            html: html,
            anchorLocation: -1,
            ownerTextView: self,
            drawnWith: drawingState,
            generation: generation
        )
        host.isMeasuring = true
        let startHeight = layoutBridge?.htmlBlockHeights[html] ?? baseFont.pointSize * 1.4
        host.frame = NSRect(x: Self.htmlBlockMeasuringOriginX - width, y: 0, width: width, height: max(startHeight, 1))
        let measurement = HTMLBlockMeasurement(host: host, layout: layout)
        htmlBlockMeasurements[html] = measurement
        addSubview(host)
        measurement.deadlineTimer = Timer.scheduledTimer(withTimeInterval: Self.htmlBlockMeasurementDeadline, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishHTMLBlockMeasurement(html) }
        }
        let view = renderer.makeView(for: content) { [weak self, weak host] reported in
            guard let self, let host, host.isActive else { return }
            self.htmlBlockMeasurement(html, didReport: reported)
        }
        host.setContent(view)
    }

    /// A measuring view reported: size the view to it as a live one would
    /// be, keep it, and wait for the reports to settle.
    private func htmlBlockMeasurement(_ html: String, didReport reported: CGFloat) {
        guard let measurement = htmlBlockMeasurements[html], reported.isFinite, reported >= 0 else { return }
        measurement.host.frame.size.height = max(ceil(reported), 1)
        measurement.lastReported = reported
        scheduleHTMLBlockMeasurementSettle(html)
    }

    private func scheduleHTMLBlockMeasurementSettle(_ html: String) {
        guard let measurement = htmlBlockMeasurements[html] else { return }
        measurement.settleTimer?.invalidate()
        measurement.settleTimer = Timer.scheduledTimer(withTimeInterval: Self.htmlBlockMeasurementSettleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.htmlBlockMeasurementSettled(html) }
        }
    }

    /// Quiet for a while: done, unless the renderer is still loading what
    /// the block shows (a slow image), in which case wait on.
    private func htmlBlockMeasurementSettled(_ html: String) {
        guard let measurement = htmlBlockMeasurements[html] else { return }
        if let view = measurement.host.content, !configuration.services.htmlBlocks.hasSettled(view) {
            scheduleHTMLBlockMeasurementSettle(html)
            return
        }
        finishHTMLBlockMeasurement(html)
    }

    private func finishHTMLBlockMeasurement(_ html: String) {
        guard let measurement = htmlBlockMeasurements.removeValue(forKey: html) else { return }
        measurement.invalidateTimers()
        if let reported = measurement.lastReported {
            htmlBlock(html, didReportHeight: reported, layout: measurement.layout)
        }
        // Measured for this layout even if it never reported (it may draw
        // nothing, or fail to load), so it isn't measured over and over.
        if let bridge = layoutBridge, bridge.htmlBlockMeasuredLayouts[html].map({ $0.matches(measurement.layout) }) != true {
            bridge.htmlBlockMeasuredLayouts[html] = measurement.layout
        }
        releaseMeasuringHost(measurement.host)
        // Start the next one.
        scheduleHTMLBlockReconcile()
    }

    /// Stops measurements for HTML not in `keeping` (edited away, or now on
    /// screen, where a live view measures it).
    private func cancelHTMLBlockMeasurements(keeping: Set<String>, renderer: any HTMLBlockRenderer) {
        for (html, measurement) in htmlBlockMeasurements where !keeping.contains(html) {
            htmlBlockMeasurements.removeValue(forKey: html)
            measurement.invalidateTimers()
            releaseMeasuringHost(measurement.host, renderer: renderer)
        }
    }

    private func releaseMeasuringHost(_ host: HTMLBlockHostView, renderer: (any HTMLBlockRenderer)? = nil) {
        host.isActive = false
        host.removeFromSuperview()
        if let view = host.takeContent() { (renderer ?? configuration.services.htmlBlocks).releaseView(view) }
    }

    // MARK: Reported heights

    /// Records a block's new content height for `layout` and restyles that
    /// block once per run-loop turn, however many views report in it. A
    /// height of 0 is real: content that draws nothing.
    func htmlBlock(_ html: String, didReportHeight reported: CGFloat, layout: HTMLBlockLayout) {
        guard let bridge = layoutBridge, reported.isFinite, reported >= 0 else { return }
        let height = ceil(reported)
        bridge.htmlBlockMeasuredLayouts[html] = layout
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
        // A block above the screen changing height would move what the reader
        // is looking at; keep the first visible line where it is.
        let anchor = topVisibleTextAnchor()
        coordinator.restyleParagraphs(paragraphs, in: self)
        if let anchor, paragraphs.contains(where: { $0.location < anchor.offset }) {
            keepTextAnchorInPlace(anchor)
        }
        updateHTMLBlockViews()
    }

    // MARK: Scroll anchoring

    /// The first layout fragment at the top of the visible rect, by document
    /// offset, and where it is now.
    private func topVisibleTextAnchor() -> (offset: Int, y: CGFloat)? {
        let visible = visibleRect
        guard !visible.isEmpty, visible.minY > 0,
              let tlm = textLayoutManager,
              let content = tlm.textContentManager else { return nil }
        let top = CGPoint(x: 0, y: visible.minY - textContainerOrigin.y)
        guard let fragment = tlm.textLayoutFragment(for: top) else { return nil }
        let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        return (offset, fragment.layoutFragmentFrame.minY)
    }

    /// Scrolls by however far the anchor's fragment moved.
    private func keepTextAnchorInPlace(_ anchor: (offset: Int, y: CGFloat)) {
        guard let tlm = textLayoutManager,
              let content = tlm.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: anchor.offset),
              let throughAnchor = NSTextRange(location: content.documentRange.location, end: location),
              let scrollView = enclosingScrollView else { return }
        tlm.ensureLayout(for: throughAnchor)
        guard let fragment = tlm.textLayoutFragment(for: location) else { return }
        let delta = fragment.layoutFragmentFrame.minY - anchor.y
        guard abs(delta) >= 0.5 else { return }
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: clipView.bounds.origin.y + delta))
        scrollView.reflectScrolledClipView(clipView)
    }
}
