//
//  WebViewPoolTests.swift
//  MarkdownEngineWebKitTests
//
//  The shared pool of block web views: views given back are handed out
//  again before any new one is made, and each use draws with its own
//  renderer's loader, scripts and remote-content switch, whichever renderer
//  (document, window) used the view before.
//

import AppKit
import Testing
import WebKit
import MarkdownEngine
@testable import MarkdownEngineWebKit

@MainActor
@Suite("WebKit HTML block renderer — shared view pool", .serialized)
struct WebViewPoolTests {

    /// Heights one use of a view reported.
    @MainActor
    private final class Reports {
        var heights: [CGFloat] = []
    }

    private static func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private let window: NSWindow = {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }()

    /// Shows `html` through `renderer` in the window and waits until a report
    /// satisfies `done`, sizing the view to each report as the editor does.
    private func show(
        _ html: String,
        with renderer: WebKitHTMLBlockRenderer,
        until done: @escaping (CGFloat) -> Bool
    ) async throws -> (view: NSView, reports: Reports) {
        let reports = Reports()
        let holder = Holder()
        let block = HTMLBlockContent(html: html, fontName: "Helvetica", fontSize: 14, theme: .default)
        let view = renderer.makeView(for: block) { height in
            reports.heights.append(height)
            holder.view?.setFrameSize(NSSize(width: 400, height: height))
        }
        holder.view = view
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 20)
        window.contentView?.addSubview(view)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !(reports.heights.last.map(done) ?? false) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return (view, reports)
    }

    @MainActor
    private final class Holder {
        weak var view: NSView?
    }

    @Test("Views given back are handed out again; none is made while one is free")
    func reuse() async throws {
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let renderer = WebKitHTMLBlockRenderer()
        let block = HTMLBlockContent(html: "<p>moss</p>", fontName: "Helvetica", fontSize: 14, theme: .default)
        let start = pool.createdCount
        let first = (0..<3).map { _ in renderer.makeView(for: block) { _ in } }
        #expect(pool.createdCount == start + 3)

        first.forEach(renderer.releaseView)
        #expect(pool.idle.count == 3)
        let second = (0..<3).map { _ in renderer.makeView(for: block) { _ in } }
        #expect(pool.createdCount == start + 3)
        #expect(Set(second.map(ObjectIdentifier.init)) == Set(first.map(ObjectIdentifier.init)))
        #expect(pool.idle.isEmpty)
        second.forEach(renderer.releaseView)
        pool.purge()
    }

    @Test("A reused view reads through the new renderer's loader, not the old one's")
    func reusedViewTakesTheNewLoader() async throws {
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let tall = try Self.png(width: 40, height: 200)
        let short = try Self.png(width: 40, height: 60)
        let folder = URL(fileURLWithPath: "/Garden", isDirectory: true)
        let firstDocument = WebKitHTMLBlockRenderer(baseURL: folder, resourceLoader: { _ in tall })
        let secondDocument = WebKitHTMLBlockRenderer(baseURL: folder, resourceLoader: { _ in short })
        let html = "<p><img src=\"fern.png\"></p>"

        let first = try await show(html, with: firstDocument) { $0 >= 200 }
        #expect((first.reports.heights.last ?? 0) >= 200)
        firstDocument.releaseView(first.view)

        let second = try await show(html, with: secondDocument) { $0 >= 60 && $0 < 200 }
        #expect(second.view === first.view)
        let height = second.reports.heights.last ?? 0
        #expect(height >= 60 && height < 200)
        secondDocument.releaseView(second.view)
        pool.purge()
    }

    @Test("A reused view runs scripts only when its new renderer allows them")
    func reusedViewTakesTheNewScriptSwitch() async throws {
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let html = """
        <div id="bed" style="height: 30px"></div>
        <script>document.getElementById('bed').style.height = '170px';</script>
        """
        let scripted = WebKitHTMLBlockRenderer(allowsJavaScript: true)
        let plain = WebKitHTMLBlockRenderer(allowsJavaScript: false)

        let first = try await show(html, with: scripted) { $0 >= 170 }
        #expect(first.reports.heights.last == 170)
        scripted.releaseView(first.view)

        let second = try await show(html, with: plain) { $0 > 0 }
        #expect(second.view === first.view)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(second.reports.heights.last == 30)
        plain.releaseView(second.view)
        pool.purge()
    }

    @Test("Keeps only so many idle views, and lets them all go on purge")
    func idleLimitAndPurge() {
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let limit = pool.idleLimit
        defer { pool.idleLimit = limit }
        pool.idleLimit = 2
        let renderer = WebKitHTMLBlockRenderer()
        let block = HTMLBlockContent(html: "<p>moss</p>", fontName: "Helvetica", fontSize: 14, theme: .default)
        let views = (0..<3).map { _ in renderer.makeView(for: block) { _ in } }
        views.forEach(renderer.releaseView)
        #expect(pool.idle.count == 2)
        pool.purge()
        #expect(pool.idle.isEmpty)
    }

    @Test("A message or request from a previous use's page reaches nothing")
    func previousUseIsIgnored() async throws {
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let renderer = WebKitHTMLBlockRenderer()
        let first = try await show("<div style=\"height: 90px\"></div>", with: renderer) { $0 >= 90 }
        let webView = try #require(first.view as? HTMLBlockWebView)
        let oldUse = try #require(webView.lease?.resourceHost)
        renderer.releaseView(first.view)

        let second = try await show("<div style=\"height: 40px\"></div>", with: renderer) { $0 >= 40 }
        #expect(second.view === first.view)
        let reports = second.reports.heights.count
        // A late report stamped with the old use, as the old page would send it.
        _ = try await webView.evaluateJavaScript(
            "window.webkit.messageHandlers.\(HeightMessageHandler.name).postMessage({ use: '\(oldUse)', height: 999 }); 0",
            in: nil,
            contentWorld: .defaultClient
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(second.reports.heights.count == reports)
        #expect(!second.reports.heights.contains(999))
        renderer.releaseView(second.view)
        pool.purge()
    }

    @Test("A released view no longer reports, even if its page still does")
    func releasedViewIsSilent() async throws {
        let pool = HTMLBlockWebViewPool.shared
        pool.purge()
        let renderer = WebKitHTMLBlockRenderer()
        let shown = try await show("<div style=\"height: 90px\"></div>", with: renderer) { $0 >= 90 }
        let count = shown.reports.heights.count
        renderer.releaseView(shown.view)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(shown.reports.heights.count == count)
        #expect(shown.view.superview == nil)
        pool.purge()
    }
}
