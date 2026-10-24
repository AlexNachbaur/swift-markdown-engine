//
//  WebKitHTMLBlockRendererTests.swift
//  MarkdownEngineWebKitTests
//

import AppKit
import Testing
import WebKit
import MarkdownEngine
@testable import MarkdownEngineWebKit

@Suite("WebKit HTML block renderer — page and URLs")
struct WebKitHTMLBlockPageTests {

    @Test("A file base becomes a folder URL in the resource scheme, spaces and all")
    func pageBaseURL() throws {
        let folder = URL(fileURLWithPath: "/Garden Notes/Spring", isDirectory: true)
        let base = try #require(ResourceSchemeHandler.pageBaseURL(for: folder))
        #expect(base.scheme == ResourceSchemeHandler.scheme)
        #expect(base.path == "/Garden Notes/Spring")
        #expect(base.absoluteString.hasSuffix("/"))
    }

    @Test("Relative references resolve the way they would against the folder")
    func relativeReferencesRoundTrip() throws {
        let folder = URL(fileURLWithPath: "/Garden Notes/Spring", isDirectory: true)
        let base = try #require(ResourceSchemeHandler.pageBaseURL(for: folder))
        let cases = [
            ("fern.png", "/Garden Notes/Spring/fern.png"),
            ("images/moss%20bed.jpg", "/Garden Notes/Spring/images/moss bed.jpg"),
            ("../shared/logo.svg", "/Garden Notes/shared/logo.svg"),
        ]
        for (reference, path) in cases {
            let resolved = try #require(URL(string: reference, relativeTo: base)?.absoluteURL)
            #expect(ResourceSchemeHandler.fileURL(for: resolved)?.path == path)
        }
    }

    @Test("Other bases and other URLs are left alone")
    func otherURLs() throws {
        let remote = try #require(URL(string: "https://example.com/docs/"))
        #expect(ResourceSchemeHandler.pageBaseURL(for: remote) == remote)
        #expect(ResourceSchemeHandler.pageBaseURL(for: nil) == nil)
        #expect(ResourceSchemeHandler.fileURL(for: remote) == nil)
    }

    @Test("A link into the document's folder opens as a file URL, keeping its fragment")
    func linkFileURL() throws {
        let link = try #require(URL(string: "markdown-engine-resource://file/Garden/notes.md#watering"))
        let file = try #require(ResourceSchemeHandler.fileURL(for: link))
        #expect(file.isFileURL)
        #expect(file.path == "/Garden/notes.md")
        #expect(file.fragment == "watering")
    }

    @Test("Same-page anchors are recognized")
    func fragmentLinks() throws {
        let page = try #require(URL(string: "markdown-engine-resource://file/Garden/"))
        let anchor = try #require(URL(string: "markdown-engine-resource://file/Garden/#beds"))
        let elsewhere = try #require(URL(string: "markdown-engine-resource://file/Garden/notes.md#beds"))
        #expect(NavigationPolicy.isFragmentLink(anchor, on: page))
        #expect(!NavigationPolicy.isFragmentLink(elsewhere, on: page))
        #expect(!NavigationPolicy.isFragmentLink(page, on: page))
    }

    @Test("MIME types come from the file extension")
    func mimeTypes() {
        #expect(ResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/fern.png")) == "image/png")
        #expect(ResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/logo.svg")) == "image/svg+xml")
        #expect(ResourceSchemeHandler.mimeType(for: URL(fileURLWithPath: "/a/unknown")) == "application/octet-stream")
    }

    @Test("System fonts map to the system family; named fonts to their family")
    func fontFamilies() {
        #expect(HTMLBlockDocument.cssFontFamily(".SFNS-Regular").hasPrefix("-apple-system"))
        #expect(HTMLBlockDocument.cssFontFamily("Helvetica-Bold").hasPrefix("\"Helvetica\""))
    }

    @Test("Colors and numbers are written as CSS")
    func cssValues() {
        #expect(HTMLBlockDocument.cssColor(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 0.25)) == "rgba(255, 128, 0, 0.25)")
        #expect(HTMLBlockDocument.cssNumber(14) == "14")
        #expect(HTMLBlockDocument.cssNumber(13.5) == "13.5")
    }

    @Test("Strings are escaped for JavaScript")
    func javaScriptStrings() {
        #expect(HTMLBlockDocument.javaScriptString("a \"b\"\nc") == #""a \"b\"\nc""#)
    }

    @Test("The page carries the block, the body font and the embedder's stylesheet")
    func page() {
        let block = HTMLBlockContent(html: "<p>moss</p>", fontName: "Helvetica", fontSize: 15, theme: .default)
        let page = HTMLBlockDocument.page(for: block, colors: ":root{}", stylesheet: "p { color: green; }")
        #expect(page.contains("<p>moss</p>"))
        #expect(page.contains("font-size: 15px"))
        #expect(page.contains("p { color: green; }"))
        #expect(page.contains("display: flow-root"))
    }

    @Test("The fingerprint follows what the renderer draws with")
    func fingerprints() {
        let folder = URL(fileURLWithPath: "/Garden", isDirectory: true)
        let first = WebKitHTMLBlockRenderer(baseURL: folder, fingerprint: 1)
        #expect(first.fingerprint() == WebKitHTMLBlockRenderer(baseURL: folder, fingerprint: 1).fingerprint())
        #expect(first.fingerprint() != WebKitHTMLBlockRenderer(baseURL: folder, fingerprint: 2).fingerprint())
        #expect(first.fingerprint() != WebKitHTMLBlockRenderer(baseURL: nil, fingerprint: 1).fingerprint())
        #expect(first.isEnabled)
    }
}

// MARK: - Live

/// Collects the resolved URLs a renderer's loader is asked for.
private final class LoaderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func record(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var requested: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

@MainActor
@Suite("WebKit HTML block renderer — live", .serialized)
struct WebKitHTMLBlockLiveTests {

    /// A solid PNG of the given pixel size.
    private static func png(width: Int, height: Int) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    /// Hosts the block's view in an offscreen window at `width` and waits
    /// until a reported height satisfies `done`. With `resizeTo`, it then
    /// resizes the view after the first report and waits for a taller one.
    ///
    /// The wait is an async sleep, not a run-loop spin: WebKit answers on the
    /// main queue, which can't drain while a test blocks inside it.
    private func render(
        _ html: String,
        renderer: WebKitHTMLBlockRenderer,
        width: CGFloat = 400,
        resizeTo newWidth: CGFloat? = nil,
        until done: @escaping (CGFloat) -> Bool
    ) async throws -> [CGFloat] {
        _ = NSApplication.shared
        let log = HeightLog()
        let block = HTMLBlockContent(html: html, fontName: "Helvetica", fontSize: 14, theme: .default)
        let view = renderer.makeView(for: block) { log.heights.append($0) }
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        view.frame = NSRect(x: 0, y: 0, width: width, height: 20)
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        func wait(until condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline, !condition() {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        guard let newWidth else {
            try await wait { log.heights.last.map(done) ?? false }
            return log.heights
        }
        try await wait { !log.heights.isEmpty }
        guard let first = log.heights.first else { return [] }
        view.setFrameSize(NSSize(width: newWidth, height: view.frame.height))
        try await wait { (log.heights.last ?? 0) > first }
        return log.heights
    }

    @Test("A block reports the height of its content")
    func reportsHeight() async throws {
        let renderer = WebKitHTMLBlockRenderer()
        let html = "<div style=\"height: 137px\"></div>"
        let heights = try await render(html, renderer: renderer) { $0 >= 137 }
        #expect(heights.last == 137)
    }

    @Test("Relative images load through the resource loader and grow the block")
    func loadsRelativeImages() async throws {
        let log = LoaderLog()
        let image = try Self.png(width: 40, height: 90)
        let folder = URL(fileURLWithPath: "/Garden Notes/Spring", isDirectory: true)
        let renderer = WebKitHTMLBlockRenderer(baseURL: folder, resourceLoader: { url in
            log.record(url)
            return url.lastPathComponent == "fern.png" ? image : nil
        })
        let html = "<p><img src=\"images/fern.png\"> <img src=\"../missing.png\" alt=\"\"></p>"
        let heights = try await render(html, renderer: renderer) { $0 >= 90 }
        #expect((heights.last ?? 0) >= 90)
        let paths = Set(log.requested.map(\.path))
        #expect(paths.contains("/Garden Notes/Spring/images/fern.png"))
        #expect(paths.contains("/Garden Notes/missing.png"))
    }

    @Test("Narrowing the column reflows the text and reports a taller height")
    func reflowsWithWidth() async throws {
        let html = "<p>" + String(repeating: "Ferns and mosses like shade. ", count: 20) + "</p>"
        let heights = try await render(html, renderer: WebKitHTMLBlockRenderer(), width: 600, resizeTo: 200) { _ in false }
        let wide = try #require(heights.first)
        #expect(wide > 0)
        #expect((heights.last ?? 0) > wide)
    }
}

/// Heights a block's view reported, in order.
@MainActor
private final class HeightLog {
    var heights: [CGFloat] = []
}
