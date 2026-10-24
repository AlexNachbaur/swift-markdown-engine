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
import MarkdownEngineWebKit

@MainActor
@Suite("WebKit HTML blocks in the editor", .serialized)
struct WebKitHTMLBlockEditorTests {

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
        let afterBefore = bridge.boundingRect(forCharacterRange: afterRange, in: container).minY

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, textView.htmlBlockViews.values.first?.frame.height != 180 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let host = try #require(textView.htmlBlockViews.values.first)
        #expect(host.frame.height == 180)
        #expect(bridge.htmlBlockHeights[html] == 180)
        let afterNow = bridge.boundingRect(forCharacterRange: afterRange, in: container).minY
        #expect(afterNow - afterBefore > 100)
        // The text after the block starts below it.
        #expect(afterNow + textView.textContainerOrigin.y >= host.frame.maxY)
    }
}
