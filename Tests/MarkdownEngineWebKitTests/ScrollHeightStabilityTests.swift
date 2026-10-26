//
//  ScrollHeightStabilityTests.swift
//  MarkdownEngineWebKitTests
//
//  The document's height must hold still while it scrolls, after the
//  embedder hands the editor new services as well as before. A full restyle
//  invalidates all of TextKit 2's layout; measured from its estimates, the
//  height drifted with every scroll step (the scroller jumped, and text near
//  the end went missing) until something forced a full layout again.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine
@testable import MarkdownEngineWebKit

@MainActor
@Suite("Document height holds while scrolling", .serialized)
struct ScrollHeightStabilityTests {
    /// A visible HTML block at the top, comments in the middle, and a long
    /// run of ordinary Markdown.
    private static let document: String = {
        var parts = [
            "# Garden",
            "<p align=\"center\"><img src=\"fern.png\" width=\"49%\"> <img src=\"moss.png\" width=\"49%\"></p>",
        ]
        for index in 0..<160 {
            if index % 10 == 0 { parts.append("## Bed \(index / 10)") }
            parts.append("Paragraph \(index): the **ferns** along the north fence need dividing, and the *moss* between the stepping stones has spread toward the shed.")
            if index % 25 == 3 { parts.append("- divide ferns\n- rake moss\n- [ ] order compost") }
            if index % 40 == 7 { parts.append("```swift\nlet bed = \(index)\n```") }
            if index % 60 == 11 { parts.append("| Bed | Plant |\n|---|---|\n| \(index) | fern |") }
            if index % 50 == 37 { parts.append("<!-- note \(index): check drainage -->") }
        }
        return parts.joined(separator: "\n\n")
    }()

    private static let image: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )
        return rep?.representation(using: .png, properties: [:]) ?? Data()
    }()

    /// An image provider whose only change is its fingerprint.
    private struct VersionedImages: EmbeddedImageProvider {
        let version: Int
        func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
        func fingerprint() -> AnyHashable { version }
    }

    private static func renderer(fingerprint: Int) -> WebKitHTMLBlockRenderer {
        let image = Self.image
        return WebKitHTMLBlockRenderer(
            baseURL: URL(fileURLWithPath: "/Garden", isDirectory: true),
            resourceLoader: { _ in image },
            fingerprint: fingerprint
        )
    }

    private static func configuration(renderer: any HTMLBlockRenderer, images: Int = 0) -> MarkdownEditorConfiguration {
        var configuration = MarkdownEditorConfiguration.default
        configuration.services = MarkdownEditorServices(images: VersionedImages(version: images), htmlBlocks: renderer)
        configuration.textInsets = TextInsets(horizontal: 24, vertical: 20)
        return configuration
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = descendant(type, in: subview) { return found }
        }
        return nil
    }

    /// Opens the document, optionally hands the editor `then`, scrolls to the
    /// end and returns the document height at every step.
    private func heightsWhileScrolling(
        _ first: MarkdownEditorConfiguration,
        then second: MarkdownEditorConfiguration? = nil
    ) async throws -> [CGFloat] {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: NativeTextViewWrapper(
            text: .constant(Self.document), configuration: first, isEditable: false
        ))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            descendant(NativeTextView.self, in: host)?.removeAllHTMLBlockViews()
            window.orderOut(nil)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        if let second {
            host.rootView = NativeTextViewWrapper(text: .constant(Self.document), configuration: second, isEditable: false)
            try await Task.sleep(nanoseconds: 800_000_000)
        }
        let scrollView = try #require(descendant(NSScrollView.self, in: host))
        let clipView = scrollView.contentView
        var heights: [CGFloat] = []
        for step in 0..<400 {
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            heights.append(documentHeight)
            let target = min(CGFloat(step) * 200, documentHeight - clipView.bounds.height)
            if step > 0 && target <= clipView.bounds.origin.y { break }
            clipView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(clipView)
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        return heights
    }

    @Test("Without a change of services, the height never moves")
    func steadyWithoutChange() async throws {
        let heights = try await heightsWhileScrolling(Self.configuration(renderer: Self.renderer(fingerprint: 1)))
        #expect(heights.count > 20)
        #expect(Set(heights).count == 1, "heights: \(Set(heights).sorted())")
    }

    @Test("After the HTML renderer's fingerprint changes, the height never moves")
    func steadyAfterRendererChange() async throws {
        let heights = try await heightsWhileScrolling(
            Self.configuration(renderer: Self.renderer(fingerprint: 1)),
            then: Self.configuration(renderer: Self.renderer(fingerprint: 2))
        )
        #expect(heights.count > 20)
        #expect(Set(heights).count == 1, "heights: \(Set(heights).sorted())")
    }

    @Test("After the image provider changes (a full restyle), the height never moves")
    func steadyAfterImageChange() async throws {
        let renderer = Self.renderer(fingerprint: 1)
        let heights = try await heightsWhileScrolling(
            Self.configuration(renderer: renderer, images: 1),
            then: Self.configuration(renderer: renderer, images: 2)
        )
        #expect(heights.count > 20)
        #expect(Set(heights).count == 1, "heights: \(Set(heights).sorted())")
    }

    @Test("After HTML blocks are switched on, the height never moves")
    func steadyAfterSwitchingOn() async throws {
        let heights = try await heightsWhileScrolling(
            Self.configuration(renderer: NoOpHTMLBlockRenderer()),
            then: Self.configuration(renderer: Self.renderer(fingerprint: 1))
        )
        #expect(heights.count > 20)
        // The new block's images may finish loading a few steps in, which
        // changes the height once; after that it holds.
        let changes = zip(heights, heights.dropFirst()).filter { $0 != $1 }.count
        #expect(changes <= 1, "heights: \(heights.map(Int.init))")
    }
}
