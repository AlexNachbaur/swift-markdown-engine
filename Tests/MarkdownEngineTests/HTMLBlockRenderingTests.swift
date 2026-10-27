//
//  HTMLBlockRenderingTests.swift
//  MarkdownEngineTests
//
//  Styling and hosting of raw HTML blocks: the styler reserves the space a
//  renderer's view reports and tags one anchor character; the text view hosts
//  one view per tagged anchor over that space. A fake renderer stands in for
//  WebKit, so the tests cover the engine's side of the contract only.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Records what the engine asks of it, and hands back plain views.
private final class RecordingHTMLBlockRenderer: HTMLBlockRenderer, @unchecked Sendable {
    let isEnabled: Bool
    @MainActor private(set) var made: [HTMLBlockContent] = []
    @MainActor private(set) var updated: [HTMLBlockContent] = []
    @MainActor private(set) var heightCallbacks: [String: @MainActor (CGFloat) -> Void] = [:]

    init(isEnabled: Bool = true) { self.isEnabled = isEnabled }

    @MainActor
    func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView {
        made.append(block)
        heightCallbacks[block.html] = heightDidChange
        return NSView()
    }

    @MainActor
    func update(_ view: NSView, for block: HTMLBlockContent) {
        updated.append(block)
    }
}

// MARK: - Styling

@MainActor
@Suite("HTML block styling")
struct HTMLBlockStylingTests {

    private static func configuration(_ renderer: any HTMLBlockRenderer) -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(htmlBlocks: renderer)
        return configuration
    }

    private static func style(_ text: String, renderer: any HTMLBlockRenderer, bridge: LayoutBridge? = nil) -> [StyledRange] {
        _ = NSApplication.shared
        return MarkdownStyler.styleAttributes(
            text: text,
            fontName: "Helvetica",
            fontSize: 14,
            layoutBridge: bridge,
            caretLocation: (text as NSString).length,
            activeTokenIndices: [],
            configuration: configuration(renderer)
        )
    }

    private static func anchors(in styled: [StyledRange]) -> [HTMLBlockAnchor] {
        styled.compactMap { $0.attributes[.htmlBlockAnchor] as? HTMLBlockAnchor }
    }

    @Test("Without a renderer, HTML is not tagged")
    func disabledLeavesHTMLAlone() {
        let styled = Self.style("<div>garden</div>\n\nafter", renderer: NoOpHTMLBlockRenderer())
        #expect(Self.anchors(in: styled).isEmpty)
    }

    @Test("A rendered block tags one anchor with its HTML and the body font")
    func renderedBlockIsTagged() {
        let html = "<div align=\"center\">\n<img src=\"fern.png\">\n</div>"
        let styled = Self.style("intro\n\n\(html)\n\nafter", renderer: RecordingHTMLBlockRenderer())
        let anchors = Self.anchors(in: styled)
        #expect(anchors.count == 1)
        #expect(anchors.first?.html == html)
        #expect(anchors.first?.fontName == NSFont(name: "Helvetica", size: 14)?.fontName)
        #expect(anchors.first?.fontSize == 14)
    }

    @Test("A block is never spell-checked")
    func blockIsNotSpellChecked() {
        let styled = Self.style("<p>mispelt wurds</p>", renderer: RecordingHTMLBlockRenderer())
        #expect(styled.contains { ($0.attributes[.spellingState] as? Int) == 0 })
    }

    @Test("The anchor line reserves the height the view last reported")
    func reservesReportedHeight() throws {
        _ = NSApplication.shared
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let tlm = try #require(textView.textLayoutManager)
        let bridge = LayoutBridge(tlm)
        let html = "<table><tr><td>fern</td><td>moss</td></tr></table>"
        bridge.htmlBlockHeights[html] = 240

        let styled = Self.style("\(html)\n\nafter", renderer: RecordingHTMLBlockRenderer(), bridge: bridge)
        let anchorRun = try #require(styled.first { $0.attributes[.htmlBlockAnchor] != nil })
        let bounds = try #require((anchorRun.attributes[.latexBounds] as? NSValue)?.rectValue)
        #expect(bounds.height == 240)
        let paragraph = styled
            .filter { NSLocationInRange(anchorRun.range.location, $0.range) }
            .compactMap { $0.attributes[.paragraphStyle] as? NSParagraphStyle }
            .last
        #expect(paragraph?.minimumLineHeight == 240)
    }

    @Test("A comment-only block renders as nothing and gets no view")
    func commentCollapses() {
        let styled = Self.style("<!-- gardening notes -->\n\nafter", renderer: RecordingHTMLBlockRenderer())
        #expect(Self.anchors(in: styled).isEmpty)
        #expect(styled.contains { ($0.attributes[.foregroundColor] as? NSColor) == .clear })
    }

    @Test("Comment detection", arguments: [
        ("<!-- a -->", true),
        ("<!-- a -->\n<!-- b -->", true),
        ("  <!-- a -->  ", true),
        ("<!-- a --><p>b</p>", false),
        ("<!-- unclosed", false),
        ("<p>a</p>", false),
    ])
    func commentDetection(html: String, expected: Bool) {
        #expect(MarkdownStyler.isCommentOnly(html) == expected)
    }
}

// MARK: - Hosting

@MainActor
@Suite("HTML block hosting")
struct HTMLBlockHostingTests {

    private static let html = "<div align=\"center\">\n<img src=\"fern.png\"> <img src=\"moss.png\">\n</div>"
    private static let document = "# Garden\n\n\(html)\n\nAfter the pictures."

    private struct Editor {
        let coordinator: NativeTextViewCoordinator
        let textView: NativeTextView
        let bridge: LayoutBridge
    }

    private func makeEditor(_ text: String, renderer: any HTMLBlockRenderer, editable: Bool = true) throws -> Editor {
        _ = NSApplication.shared
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "Helvetica", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(htmlBlocks: renderer)
        coordinator.configuration = configuration
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.configuration = configuration
        textView.isEditable = editable
        textView.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.documentView = textView
        coordinator.textView = textView
        let bridge = LayoutBridge(try #require(textView.textLayoutManager))
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        coordinator.lastSyncedText = text
        coordinator.lastComputedStorage = text
        coordinator.previousDisplayLength = (text as NSString).length
        return Editor(coordinator: coordinator, textView: textView, bridge: bridge)
    }

    /// Lets the coalesced restyle a height report schedules run.
    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func afterParagraphY(_ editor: Editor) -> CGFloat {
        // Hosting settles layout only through the last block; lay out the
        // rest, as scrolling it into view would.
        if let tlm = editor.textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
        let ns = editor.textView.string as NSString
        let range = ns.range(of: "After the pictures.")
        let container = editor.bridge.firstTextContainer!
        return editor.bridge.boundingRect(forCharacterRange: range, in: container).minY
    }

    @Test("A rendered block gets one view over its reserved space, the column's width")
    func viewCoversReservedSpace() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        let textView = editor.textView

        #expect(renderer.made.map(\.html) == [Self.html])
        #expect(renderer.made.first?.fontSize == 14)
        let host = try #require(textView.htmlBlockViews.values.first)
        #expect(textView.htmlBlockViews.count == 1)
        #expect(host.superview === textView)
        #expect(!host.isHidden)

        let container = try #require(editor.bridge.firstTextContainer)
        #expect(host.frame.minX == textView.textContainerOrigin.x + container.lineFragmentPadding)
        #expect(host.frame.width == container.size.width - container.lineFragmentPadding * 2)
        // The block sits between the heading and the paragraph after it.
        #expect(host.frame.minY > 0)
        #expect(host.frame.maxY <= afterParagraphY(editor) + textView.textContainerOrigin.y)
    }

    @Test("Without a renderer, no views are hosted")
    func disabledHostsNothing() throws {
        let renderer = RecordingHTMLBlockRenderer(isEnabled: false)
        let editor = try makeEditor(Self.document, renderer: renderer)
        #expect(renderer.made.isEmpty)
        #expect(editor.textView.htmlBlockViews.isEmpty)
    }

    @Test("A height report resizes the view and pushes the following text down")
    func heightReportReflows() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        let host = try #require(editor.textView.htmlBlockViews.values.first)
        let initialHeight = host.frame.height
        let initialAfterY = afterParagraphY(editor)

        let report = try #require(renderer.heightCallbacks[Self.html])
        report(239.4)
        #expect(editor.bridge.htmlBlockHeights[Self.html] == 240)
        drainMainRunLoop()

        #expect(host.frame.height == 240)
        let moved = afterParagraphY(editor) - initialAfterY
        #expect(abs(moved - (240 - initialHeight)) < 1)
        // The same view is kept; reflow never remakes it.
        #expect(renderer.made.count == 1)
    }

    @Test("An unchanged height report is ignored")
    func unchangedHeightIgnored() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        let report = try #require(renderer.heightCallbacks[Self.html])
        report(120)
        drainMainRunLoop()
        // Heights are rounded up to whole points, so this is the same height.
        report(119.6)
        #expect(editor.textView.htmlBlocksAwaitingRestyle.isEmpty)
    }

    @Test("The caret inside a block shows its source and hides the view; leaving restores the same view")
    func caretRevealsSource() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        let textView = editor.textView
        let host = try #require(textView.htmlBlockViews.values.first)
        let blockStart = (textView.string as NSString).range(of: Self.html).location

        textView.setSelectedRange(NSRange(location: blockStart + 3, length: 0))
        #expect(host.isHidden)
        // Hidden, it must not take the clicks meant for the source under it.
        #expect(host.hitTest(NSPoint(x: host.frame.midX, y: host.frame.midY)) == nil)
        var tagged = false
        textView.textStorage?.enumerateAttribute(.htmlBlockAnchor, in: NSRange(location: 0, length: textView.textStorage?.length ?? 0)) { value, _, _ in
            if value != nil { tagged = true }
        }
        #expect(!tagged)

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        #expect(!host.isHidden)
        #expect(textView.htmlBlockViews.values.first === host)
        #expect(renderer.made.count == 1)
    }

    @Test("In edit mode the block takes clicks and puts the caret into it; read-only, its content does")
    func hitTesting() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editable = try makeEditor(Self.document, renderer: renderer, editable: true)
        let host = try #require(editable.textView.htmlBlockViews.values.first)
        let inside = NSPoint(x: host.frame.midX, y: host.frame.midY)
        #expect(host.hitTest(inside) === host)

        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        host.mouseDown(with: event)
        #expect(editable.textView.selectedRange().location == host.anchorTextLocation)

        let readOnly = try makeEditor(Self.document, renderer: RecordingHTMLBlockRenderer(), editable: false)
        let readOnlyHost = try #require(readOnly.textView.htmlBlockViews.values.first)
        let readOnlyInside = NSPoint(x: readOnlyHost.frame.midX, y: readOnlyHost.frame.midY)
        #expect(readOnlyHost.hitTest(readOnlyInside) === readOnlyHost.content)
    }

    @Test("A block edited away is hidden at once and dropped after a while")
    func removedBlockIsPruned() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        let host = try #require(editor.textView.htmlBlockViews.values.first)

        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: "# Garden\n\nNo pictures.")
        #expect(host.isHidden)
        for _ in 0..<40 { editor.textView.updateHTMLBlockViews() }
        #expect(editor.textView.htmlBlockViews.isEmpty)
        #expect(host.superview == nil)
    }

    @Test("A theme change reaches existing views through update, without remaking them")
    func themeChangeUpdatesViews() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        editor.textView.updateHTMLBlockViews()
        #expect(renderer.updated.isEmpty)

        editor.textView.configuration.theme.link = .systemPink
        editor.textView.updateHTMLBlockViews()
        #expect(renderer.updated.count == 1)
        #expect(renderer.made.count == 1)
        editor.textView.updateHTMLBlockViews()
        #expect(renderer.updated.count == 1)
    }

    @Test("Heights for HTML no longer in the document are forgotten")
    func staleHeightsPruned() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        editor.bridge.htmlBlockHeights["<p>an older edit</p>"] = 50
        editor.bridge.htmlBlockHeights[Self.html] = 120
        editor.textView.updateHTMLBlockViews()
        #expect(editor.bridge.htmlBlockHeights["<p>an older edit</p>"] == nil)
        #expect(editor.bridge.htmlBlockHeights[Self.html] == 120)
    }

    @Test("Identical blocks get a view each")
    func identicalBlocksAreDistinct() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor("\(Self.html)\n\nbetween\n\n\(Self.html)\n\nend", renderer: renderer)
        #expect(editor.textView.htmlBlockViews.count == 2)
        let frames = editor.textView.htmlBlockViews.values.map(\.frame.minY).sorted()
        #expect(frames.count == 2 && frames[0] < frames[1])
    }

    @Test("Switching the renderer on or off, or changing its fingerprint, changes what the wrapper compares")
    func rendererFingerprint() {
        struct Versioned: HTMLBlockRenderer {
            let version: Int
            var isEnabled: Bool { true }
            func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView { NSView() }
            func update(_ view: NSView, for block: HTMLBlockContent) {}
            func fingerprint() -> AnyHashable { version }
        }
        let off = MarkdownEditorServices().htmlBlockFingerprint
        let on = MarkdownEditorServices(htmlBlocks: RecordingHTMLBlockRenderer()).htmlBlockFingerprint
        #expect(off != on)
        #expect(MarkdownEditorServices(htmlBlocks: Versioned(version: 1)).htmlBlockFingerprint
                != MarkdownEditorServices(htmlBlocks: Versioned(version: 2)).htmlBlockFingerprint)
    }

    @Test("A height reported just before every view is removed still reaches the text")
    func removeAllKeepsQueuedRestyle() throws {
        let renderer = RecordingHTMLBlockRenderer()
        let editor = try makeEditor(Self.document, renderer: renderer)
        let initialAfterY = afterParagraphY(editor)
        let report = try #require(renderer.heightCallbacks[Self.html])
        report(180)
        // A renderer change lands in the same turn as the report.
        editor.textView.removeAllHTMLBlockViews()
        #expect(editor.textView.htmlBlockViews.isEmpty)
        drainMainRunLoop()
        // The remade view would report 180 again, which is ignored as
        // unchanged; the queued restyle must already have reserved it.
        #expect(afterParagraphY(editor) - initialAfterY > 100)
    }
}
