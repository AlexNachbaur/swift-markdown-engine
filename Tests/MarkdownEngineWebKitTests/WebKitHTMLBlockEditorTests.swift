//
//  WebKitHTMLBlockEditorTests.swift
//  MarkdownEngineWebKitTests
//
//  The WebKit renderer inside a live editor: the height WebKit reports must
//  reach the text layout, so the text after a block moves to make room.
//

import AppKit
import SwiftUI
import Testing
import WebKit
@testable import MarkdownEngine
@testable import MarkdownEngineWebKit

@MainActor
@Suite("WebKit HTML blocks in the editor", .serialized)
struct WebKitHTMLBlockEditorTests {

    @Test("Forty blocks: few web views, every height measured, scrolling reuses views")
    func manyBlocksStayBounded() async throws {
        _ = NSApplication.shared
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let settle = NativeTextView.htmlBlockMeasurementSettleDelay
        NativeTextView.htmlBlockMeasurementSettleDelay = 0.1
        defer { NativeTextView.htmlBlockMeasurementSettleDelay = settle }

        let filler = (0..<6).map { "Planting note \($0) for this bed." }.joined(separator: "\n\n")
        let blocks = (0..<40).map { "<div style=\"height: 60px\">Bed \($0)</div>" }
        let text = blocks.map { "\($0)\n\n\(filler)" }.joined(separator: "\n\n")

        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "Helvetica", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(htmlBlocks: WebKitHTMLBlockRenderer())
        coordinator.configuration = configuration
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        textView.configuration = configuration
        textView.isEditable = false
        textView.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scrollView.documentView = textView
        coordinator.textView = textView
        let bridge = LayoutBridge(try #require(textView.textLayoutManager))
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer {
            textView.removeAllHTMLBlockViews()
            window.orderOut(nil)
            pool.purge()
        }

        let tlm = try #require(textView.textLayoutManager)
        let sizeToContent = {
            tlm.ensureLayout(for: tlm.documentRange)
            let height = tlm.usageBoundsForTextContainer.height + textView.textContainerOrigin.y * 2
            textView.setFrameSize(NSSize(width: 600, height: max(height, 500)))
        }
        let start = pool.createdCount
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        sizeToContent()

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, bridge.htmlBlockHeights.count < blocks.count || !textView.htmlBlockMeasurements.isEmpty {
            try await Task.sleep(nanoseconds: 100_000_000)
            sizeToContent()
        }
        #expect(bridge.htmlBlockHeights.count == blocks.count)
        #expect(Set(bridge.htmlBlockHeights.values) == [60])
        let createdWhileOpening = pool.createdCount - start
        // The blocks near the screen plus the ones being measured, at the
        // busiest moment; nowhere near one per block.
        #expect(textView.htmlBlockViews.count < 10)
        #expect(createdWhileOpening <= 10)

        // Scroll to the end: the views near the top go back and come out again.
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: 0, y: textView.frame.height - 500))
        scrollView.reflectScrolledClipView(clipView)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(textView.htmlBlockViews.values.contains { $0.html == blocks.last })
        #expect(pool.createdCount - start - createdWhileOpening <= 2)
    }

    @Test("A block grows to its content and pushes the following text down")
    func blockReflowsDocument() async throws {
        _ = NSApplication.shared
        let html = "<div style=\"height: 180px\">Garden plan</div>"
        let text = "# Beds\n\n\(html)\n\nAfter the plan."

        let coordinator = NativeTextViewCoordinator(
            text: .constant(text), fontName: "Helvetica", fontSize: 14,
            isWikiLinkActive: .constant(false), onLinkClick: nil, onInlineSelectionChange: nil
        )
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(htmlBlocks: WebKitHTMLBlockRenderer())
        coordinator.configuration = configuration
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        textView.configuration = configuration
        textView.isEditable = false
        textView.delegate = coordinator
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        scrollView.documentView = textView
        coordinator.textView = textView
        let bridge = LayoutBridge(try #require(textView.textLayoutManager))
        coordinator.layoutBridge = bridge
        textView.layoutBridge = bridge

        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 500),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scrollView
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        textView.setSelectedRange(NSRange(location: 0, length: 0))
        coordinator.rebuildTextStorageAndStyle(textView, from: text)

        let container = try #require(bridge.firstTextContainer)
        let afterRange = (text as NSString).range(of: "After the plan.")
        let tlm = try #require(textView.textLayoutManager)
        let afterY = {
            tlm.ensureLayout(for: tlm.documentRange)
            return bridge.boundingRect(forCharacterRange: afterRange, in: container).minY
        }
        let afterBefore = afterY()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, textView.htmlBlockViews.values.first?.frame.height != 180 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let host = try #require(textView.htmlBlockViews.values.first)
        #expect(host.frame.height == 180)
        #expect(bridge.htmlBlockHeights[html] == 180)
        let afterNow = afterY()
        #expect(afterNow - afterBefore > 100)
        // The text after the block starts below it.
        #expect(afterNow + textView.textContainerOrigin.y >= host.frame.maxY)
    }
}
