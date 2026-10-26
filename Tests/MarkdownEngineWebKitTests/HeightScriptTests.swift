//
//  HeightScriptTests.swift
//  MarkdownEngineWebKitTests
//
//  The height script's reporting rules, run in JavaScriptCore against a
//  stubbed DOM, so each sequence of resizes and growth is exact rather than
//  left to WebKit's timing.
//

import JavaScriptCore
import Testing
@testable import MarkdownEngineWebKit

@Suite("WebKit HTML block renderer — height script")
struct HeightScriptTests {

    /// A JavaScript context with just enough DOM for the height script: a body
    /// whose height and a window whose inner height the test sets, and a
    /// ResizeObserver the test fires.
    private final class Page {
        let context: JSContext

        init(viewport: Int, body: Int) throws {
            context = try #require(JSContext())
            context.evaluateScript("""
                var posted = [];
                var observers = [];
                var bodyHeight = \(body);
                var window = {
                  innerHeight: \(viewport),
                  addEventListener: function () {},
                  webkit: { messageHandlers: { \(HeightMessageHandler.name): {
                    postMessage: function (m) { if (m.use === 'use-test') posted.push(m.height); }
                  } } }
                };
                var document = {
                  body: { getBoundingClientRect: function () { return { height: bodyHeight }; } },
                  querySelector: function () { return { content: 'use-test' }; }
                };
                function ResizeObserver(callback) { observers.push(callback); this.observe = function () {}; }
                """)
            context.evaluateScript(HTMLBlockDocument.heightScript)
        }

        func set(viewport: Int? = nil, body: Int? = nil) {
            if let viewport { context.evaluateScript("window.innerHeight = \(viewport);") }
            if let body { context.evaluateScript("bodyHeight = \(body);") }
            context.evaluateScript("observers.forEach(function (o) { o(); });")
        }

        var posted: [Int] {
            (context.evaluateScript("posted")?.toArray() ?? []).compactMap { ($0 as? NSNumber)?.intValue }
        }
    }

    @Test("Content that grows while the view is resized for another reason is reported")
    func growthDuringUnrelatedResize() throws {
        let page = try Page(viewport: 20, body: 20)
        #expect(page.posted == [20])
        // The editor sizes the view to its placeholder line just as an image loads.
        page.set(viewport: 28, body: 263)
        #expect(page.posted == [20, 263])
    }

    @Test("Content sized by the viewport settles after one report")
    func viewportSizedContentSettles() throws {
        // A 100vh element plus 33 points of text.
        let page = try Page(viewport: 20, body: 53)
        #expect(page.posted == [53])
        page.set(viewport: 53, body: 86)
        page.set()
        #expect(page.posted == [53])
        // Something real changes later: an image loads below.
        page.set(body: 186)
        #expect(page.posted == [53, 186])
    }

    @Test("Sizing the view to its own report is quiet; later growth is reported")
    func ordinaryContent() throws {
        let page = try Page(viewport: 20, body: 120)
        page.set(viewport: 120)
        #expect(page.posted == [120])
        page.set(body: 300)
        #expect(page.posted == [120, 300])
        // A narrower column reflows text taller with no viewport change.
        page.set(body: 340)
        #expect(page.posted == [120, 300, 340])
    }
}
