//
//  HTMLBlockViewportTests.swift
//  MarkdownEngineTests
//
//  Views for HTML blocks follow the screen: only blocks on or near it get
//  one, a view that scrolls away goes back to the renderer, blocks without a
//  height for the current column width are measured off screen, and a block
//  above the screen changing height doesn't move what the reader sees.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

/// Hands out views from its own reuse pool, making one only when none is
/// free, and reports a fixed height for each block on the next run-loop turn,
/// as a web view would.
private final class PoolingRenderer: HTMLBlockRenderer, @unchecked Sendable {
    let heights: [String: CGFloat]
    @MainActor private(set) var created = 0
    @MainActor private(set) var released: [NSView] = []
    @MainActor private(set) var madeFor: [String] = []
    @MainActor private var idle: [NSView] = []

    init(heights: [String: CGFloat]) { self.heights = heights }

    var isEnabled: Bool { true }

    @MainActor
    func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView {
        madeFor.append(block.html)
        let view: NSView
        if let reused = idle.popLast() {
            view = reused
        } else {
            created += 1
            view = NSView()
        }
        let height = heights[block.html] ?? 40
        RunLoop.main.perform { MainActor.assumeIsolated { heightDidChange(height) } }
        return view
    }

    @MainActor
    func update(_ view: NSView, for block: HTMLBlockContent) {}

    @MainActor
    func releaseView(_ view: NSView) {
        released.append(view)
        idle.append(view)
    }
}

@MainActor
@Suite("HTML block views follow the screen", .serialized)
struct HTMLBlockViewportTests {
    private static let top = "<div class=\"top\">beds</div>"
    private static let bottom = "<div class=\"bottom\">compost</div>"
    private static let document = {
        let filler = (0..<120).map { "Filler paragraph \($0) about the garden." }.joined(separator: "\n\n")
        return "\(top)\n\n\(filler)\n\n\(bottom)\n\nThe end."
    }()

    private struct Editor {
        let coordinator: NativeTextViewCoordinator
        let textView: NativeTextView
        let scrollView: NSScrollView
        let bridge: LayoutBridge
        var width: CGFloat {
            let container = bridge.firstTextContainer!
            return container.size.width - container.lineFragmentPadding * 2
        }
    }

    private func makeEditor(renderer: PoolingRenderer) throws -> Editor {
        _ = NSApplication.shared
        NativeTextView.htmlBlockMeasurementSettleDelay = 0.05
        let text = Self.document
        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "Helvetica", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(htmlBlocks: renderer)
        coordinator.configuration = configuration
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        textView.configuration = configuration
        textView.isEditable = false
        textView.delegate = coordinator
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
        let editor = Editor(coordinator: coordinator, textView: textView, scrollView: scrollView, bridge: bridge)
        sizeToContent(editor)
        textView.updateHTMLBlockViews()
        return editor
    }

    /// The tests host no wrapper to size the text view; grow it to its text,
    /// as the editor does, so there is something to scroll.
    private func sizeToContent(_ editor: Editor) {
        guard let tlm = editor.textView.textLayoutManager else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        let height = tlm.usageBoundsForTextContainer.height + editor.textView.textContainerOrigin.y * 2
        editor.textView.setFrameSize(NSSize(width: 600, height: max(height, 400)))
    }

    /// Runs the main run loop for a while, so reports, restyles, measurement
    /// timers and scroll reconciles happen.
    private func drain(_ seconds: TimeInterval = 0.3) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func scroll(_ editor: Editor, toY y: CGFloat) {
        let clipView = editor.scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: y))
        editor.scrollView.reflectScrolledClipView(clipView)
    }

    private func liveHTML(_ editor: Editor) -> Set<String> {
        Set(editor.textView.htmlBlockViews.values.filter { !$0.isHidden }.map(\.html))
    }

    @Test("Only a block near the screen gets a live view; the far one is measured off screen")
    func farBlockIsMeasured() throws {
        let renderer = PoolingRenderer(heights: [Self.top: 120, Self.bottom: 260])
        let editor = try makeEditor(renderer: renderer)
        #expect(liveHTML(editor) == [Self.top])
        #expect(editor.textView.htmlBlockMeasurements.keys.contains(Self.bottom))

        drain()
        #expect(editor.bridge.htmlBlockHeights[Self.bottom] == 260)
        #expect(editor.bridge.htmlBlockMeasuredWidths[Self.bottom] == editor.width)
        #expect(editor.textView.htmlBlockMeasurements.isEmpty)
        // The measuring view went back once its height settled.
        #expect(renderer.released.count == 1)
        #expect(editor.textView.subviews.allSatisfy { ($0 as? HTMLBlockHostView)?.isMeasuring != true })
    }

    @Test("Scrolling gives the far view back and reuses it, making no new view")
    func scrollingReusesViews() throws {
        let renderer = PoolingRenderer(heights: [Self.top: 120, Self.bottom: 260])
        let editor = try makeEditor(renderer: renderer)
        drain()
        sizeToContent(editor)
        let createdBefore = renderer.created

        scroll(editor, toY: editor.textView.frame.height - 400)
        drain()
        #expect(liveHTML(editor) == [Self.bottom])
        #expect(renderer.created == createdBefore)

        scroll(editor, toY: 0)
        drain()
        #expect(liveHTML(editor) == [Self.top])
        #expect(renderer.created == createdBefore)
    }

    @Test("A block above the screen growing keeps the text in view where it was")
    func growthAboveKeepsScrollPosition() throws {
        let renderer = PoolingRenderer(heights: [Self.top: 120, Self.bottom: 260])
        let editor = try makeEditor(renderer: renderer)
        drain()
        sizeToContent(editor)
        scroll(editor, toY: 2_000)
        drain()
        #expect(!liveHTML(editor).contains(Self.top))

        let visibleTop = editor.textView.visibleRect.minY
        let probe = CGPoint(x: 40, y: visibleTop + 5 - editor.textView.textContainerOrigin.y)
        let tlm = try #require(editor.textView.textLayoutManager)
        let before = try #require(tlm.textLayoutFragment(for: probe)).rangeInElement.location

        // The top block, off screen above, reports a much taller height.
        editor.textView.htmlBlock(Self.top, didReportHeight: 420, width: editor.width)
        drain()
        sizeToContent(editor)

        let moved = editor.textView.visibleRect.minY - visibleTop
        #expect(abs(moved - 300) < 2)
        let newProbe = CGPoint(x: 40, y: editor.textView.visibleRect.minY + 5 - editor.textView.textContainerOrigin.y)
        let after = try #require(tlm.textLayoutFragment(for: newProbe)).rangeInElement.location
        #expect(after.compare(before) == .orderedSame)
    }

    @Test("A height measured at another column width is measured again")
    func otherWidthIsRemeasured() throws {
        let renderer = PoolingRenderer(heights: [Self.top: 120, Self.bottom: 260])
        let editor = try makeEditor(renderer: renderer)
        drain()
        #expect(editor.textView.htmlBlockMeasurements.isEmpty)

        editor.bridge.htmlBlockMeasuredWidths[Self.bottom] = editor.width + 80
        editor.textView.updateHTMLBlockViews()
        #expect(editor.textView.htmlBlockMeasurements.keys.contains(Self.bottom))
        drain()
        #expect(editor.bridge.htmlBlockMeasuredWidths[Self.bottom] == editor.width)
    }

    @Test("Removing every view gives each back to the renderer")
    func removeAllReleases() throws {
        let renderer = PoolingRenderer(heights: [Self.top: 120, Self.bottom: 260])
        let editor = try makeEditor(renderer: renderer)
        // One live view and one measuring view are out.
        editor.textView.removeAllHTMLBlockViews()
        #expect(renderer.released.count == 2)
        #expect(editor.textView.htmlBlockViews.isEmpty)
        #expect(editor.textView.htmlBlockMeasurements.isEmpty)
        drain()
    }
}
