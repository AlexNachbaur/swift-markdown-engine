//
//  WritingToolsCoordinatorPreviewTests.swift
//  MarkdownEngineTests
//
//  The doubled words below an inline rewrite on macOS 27: Writing Tools slides
//  a snapshot of the text below the edit into place, and without
//  `NativeTextView.didChangeText`'s commit that snapshot shows the lines where
//  they stood BEFORE the rewrite. Drives NSWritingToolsCoordinator with a
//  hand-made WTSession (no Apple Intelligence) and checks every line of the
//  snapshot against where TextKit has it at that moment.
//
//  Skips, not passes, when the machinery is absent or shaped differently from
//  macOS 27.0.1 (`drivenABI`), or never asks for a snapshot (a CI VM).
//

import AppKit
import ObjectiveC
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Writing Tools remainder snapshot", .serialized)
struct WritingToolsCoordinatorPreviewTests {

    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func longerRewriteSnapshotsTheTextBelowWhereItLands() async throws {
        let report = try #require(await CoordinatorDrive.cachedLongReport())
        check(report)
    }

    @Test(.enabled("no Writing Tools coordinator machinery in this process") { await CoordinatorDrive.cachedLongReport() != nil })
    func shorterRewriteInAReadingColumnUnderAHeader() async throws {
        let variant = CoordinatorDrive.Variant(readingWidth: 650, header: true, longRewrite: false)
        var report = await CoordinatorDrive.run(variant)
        if report == nil { report = await CoordinatorDrive.run(variant) }
        check(try #require(report))
    }

    private func check(_ report: CoordinatorDrive.Report) {
        #expect(report.inkOffset != nil, "could not read the glyph offset off the pre-edit snapshot: \(report)")
        #expect(report.expectedLineTops.count >= 3, "too few lines below the edit to judge: \(report)")
        #expect(report.missingLineTops.isEmpty,
                "snapshot lacks lines at their current positions \(report.missingLineTops); bands \(report.bands)")
    }
}

// MARK: - The drive

@MainActor
private enum CoordinatorDrive {
    struct Variant {
        let readingWidth: CGFloat?
        let header: Bool
        let longRewrite: Bool
    }

    struct Report: CustomStringConvertible {
        /// Ink band tops of the remainder snapshot, points from its top.
        var bands: [CGFloat] = []
        /// Tops of the lines below the edit, as TextKit had them when AppKit asked.
        var expectedLineTops: [CGFloat] = []
        var missingLineTops: [CGFloat] = []
        /// Glyph ink below a line's top, read off the pre-edit snapshot.
        var inkOffset: CGFloat?
        var description: String { "bands \(bands) expected \(expectedLineTops) inkOffset \(String(describing: inkOffset))" }
    }

    /// Probe + cache in one: serves the gate and the first test.
    private static var longReport: Report??

    static func cachedLongReport() async -> Report? {
        if let cached = longReport { return cached }
        let report = await run(.init(readingWidth: nil, header: false, longRewrite: true))
        longReport = .some(report)
        return report
    }

    // MARK: Gate

    /// Every private method the drive calls, with its type encoding as measured on
    /// macOS 27.0.1; any other shape skips instead of corrupting the stack.
    private static let drivenABI: [(cls: String, sel: String, encoding: String)] = [
        ("NSTextView", "_ensureWritingToolsCoordinatorCreated", "@16@0:8"),
        ("NSTextView", "writingToolsCoordinator:requestsPreviewForRect:inContext:completion:", "v72@0:8@16{CGRect={CGPoint=dd}{CGSize=dd}}24@56@?64"),
        ("NSWritingToolsCoordinator", "willBeginWritingToolsSession:requestContexts:", "v32@0:8@16@?24"),
        ("NSWritingToolsCoordinator", "didBeginWritingToolsSession:contexts:", "v32@0:8@16@24"),
        ("NSWritingToolsCoordinator", "writingToolsSession:didReceiveAction:", "v32@0:8@16q24"),
        ("NSWritingToolsCoordinator", "compositionSession:didReceiveText:replacementRange:inContext:finished:", "v60@0:8@16@24{_NSRange=QQ}32@48B56"),
        ("NSWritingToolsCoordinator", "didEndWritingToolsSession:accepted:", "v28@0:8@16B24"),
        ("WTSession", "initWithType:textViewDelegate:", "@32@0:8q16@24"),
        ("WTSession", "setCompositionSessionType:", "v24@0:8q16"),
        ("WTContext", "range", "{_NSRange=QQ}16@0:8"),
    ]

    private static var machineryPresent: Bool {
        guard #available(macOS 15.2, *) else { return false }
        return drivenABI.allSatisfy { entry in
            guard let cls = NSClassFromString(entry.cls),
                  let method = class_getInstanceMethod(cls, NSSelectorFromString(entry.sel)),
                  let encoding = method_getTypeEncoding(method) else { return false }
            return String(cString: encoding) == entry.encoding
        }
    }

    // MARK: Recording hook (installed once per process; calls NSTextView's IMP)

    private struct Snapshot {
        let rect: CGRect
        let lineTops: [CGFloat]
        var bands: [CGFloat]?
    }
    private final class Recorder {
        var snapshots: [ObjectIdentifier: [Snapshot]] = [:]
    }
    private static let recorder = Recorder()
    private static var hookInstalled = false

    private static func installHook() -> Bool {
        if hookInstalled { return true }
        guard #available(macOS 15.2, *) else { return false }
        let cls: AnyClass = NativeTextView.self
        let sel = NSSelectorFromString("writingToolsCoordinator:requestsPreviewForRect:inContext:completion:")
        guard let method = class_getInstanceMethod(cls, sel),
              let original = class_getMethodImplementation(cls, sel) else { return false }
        typealias Completion = @convention(block) (NSTextPreview?) -> Void
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject, NSRect, AnyObject, Completion) -> Void
        let call = unsafeBitCast(original, to: Original.self)
        let block: @convention(block) (AnyObject, AnyObject, NSRect, AnyObject, @escaping Completion) -> Void = { me, coordinator, rect, context, done in
            let key = ObjectIdentifier(me)
            let tops = (me as? NSTextView).map { lineTops($0, in: rect) } ?? []
            recorder.snapshots[key, default: []].append(Snapshot(rect: rect, lineTops: tops))
            let index = recorder.snapshots[key]!.count - 1
            call(me, sel, coordinator, rect, context) { preview in
                if let image = preview?.previewImage {
                    recorder.snapshots[key]?[index].bands = inkBandTops(image, pointsTall: rect.height)
                }
                done(preview)
            }
        }
        class_replaceMethod(cls, sel, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        hookInstalled = true
        return true
    }

    /// Tops of the lines with text inside `rect`, points from its top.
    private static func lineTops(_ tv: NSTextView, in rect: CGRect) -> [CGFloat] {
        guard let tlm = tv.textLayoutManager else { return [] }
        let origin = tv.textContainerOrigin
        var tops: [CGFloat] = []
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > rect.maxY { return false }
            if frame.maxY >= rect.minY {
                // Blank paragraphs carry no ink, so no band to find.
                for line in fragment.textLineFragments
                where !line.attributedString.attributedSubstring(from: line.characterRange).string
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tops.append(frame.minY + line.typographicBounds.minY - rect.minY)
                }
            }
            return true
        }
        return tops
    }

    /// Tops of the horizontal bands that carry ink, points from the image's top.
    private static func inkBandTops(_ image: CGImage, pointsTall: CGFloat) -> [CGFloat] {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return [] }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let scale = CGFloat(height) / pointsTall
        var tops: [CGFloat] = []
        var inInk = false
        for row in 0..<height {   // memory row 0 is the image's top
            var ink = false
            for x in 0..<width where pixels[(row * width + x) * 4 + 3] > 40 { ink = true; break }
            if ink && !inInk { tops.append(CGFloat(row) / scale) }
            inInk = ink
        }
        return tops
    }

    // MARK: Hosting

    private struct Host: View {
        @State var text: String
        let readingWidth: CGFloat?
        let header: Bool
        var body: some View {
            var config = MarkdownEditorConfiguration.default
            config.readingWidth = readingWidth
            return NativeTextViewWrapper(
                text: $text,
                configuration: config,
                header: header ? AnyView(Color.gray.frame(height: 60)) : nil
            )
        }
    }

    private static let markdown = (1...120).map {
        "Paragraph \($0). The quick brown fox jumps over the lazy dog while the writing tools think about it."
    }.joined(separator: "\n\n")

    /// AppKit keeps effect work in flight past the session; a torn-down window under it crashes the host.
    private static var windows: [NSWindow] = []

    private static func findViews(_ root: NSView) -> (NSScrollView, NativeTextView)? {
        if let sv = root as? NSScrollView, let tv = sv.nativeTextView { return (sv, tv) }
        for sub in root.subviews {
            if let found = findViews(sub) { return found }
        }
        return nil
    }

    private static func runLoopSlice() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    /// Async on purpose: the coordinator answers through the main queue, which a
    /// run loop nested inside a main-actor test body never drains. Sleeping hands
    /// the main queue back; the run-loop slice keeps timers and CA commits going.
    private static func spin(_ seconds: TimeInterval) async {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while Date() < deadline {
            runLoopSlice()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func spin(until condition: () -> Bool, limit: TimeInterval) async -> Bool {
        let deadline = Date(timeIntervalSinceNow: limit)
        while Date() < deadline {
            if condition() { return true }
            await spin(0.02)
        }
        return condition()
    }

    // MARK: The session

    private final class ContextBox {
        var contexts: [NSObject]?
    }

    /// `nil` = the machinery is absent or never asked for the remainder snapshot.
    static func run(_ variant: Variant) async -> Report? {
        guard machineryPresent, installHook() else { return nil }
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Host(text: markdown, readingWidth: variant.readingWidth, header: variant.header))
        window.orderFrontRegardless()
        windows.append(window)
        defer { window.orderOut(nil) }

        var found: (NSScrollView, NativeTextView)?
        guard await spin(until: { found = findViews(window.contentView!); return found != nil }, limit: 3),
              let (sv, tv) = found, let tlm = tv.textLayoutManager else { return nil }
        await spin(0.4)
        recorder.snapshots[ObjectIdentifier(tv)] = []

        // Select paragraph 40 and put it near the top: plenty of text below it.
        let ns = tv.string as NSString
        let paragraph = ns.paragraphRange(for: NSRange(location: ns.range(of: "Paragraph 40.").location, length: 0))
        let selection = NSRange(location: paragraph.location, length: paragraph.length - 1)
        tv.setSelectedRange(selection)
        tlm.ensureLayout(for: tlm.documentRange)
        guard let start = tlm.location(tlm.documentRange.location, offsetBy: selection.location),
              let fragment = tlm.textLayoutFragment(for: start) else { return nil }
        let top = sv.documentView!.convert(NSPoint(x: 0, y: fragment.layoutFragmentFrame.minY + tv.textContainerOrigin.y), from: tv).y
        sv.contentView.scroll(to: NSPoint(x: 0, y: max(0, top - 100)))
        sv.reflectScrolledClipView(sv.contentView)
        window.makeFirstResponder(tv)
        window.displayIfNeeded()
        await spin(0.1)

        let ensureSel = NSSelectorFromString("_ensureWritingToolsCoordinatorCreated")
        let initSel = NSSelectorFromString("initWithType:textViewDelegate:")
        typealias Getter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
        typealias Init = @convention(c) (AnyObject, Selector, Int, AnyObject?) -> Unmanaged<AnyObject>
        guard let ensureIMP = tv.method(for: ensureSel),
              let coordinator = unsafeBitCast(ensureIMP, to: Getter.self)(tv, ensureSel)?.takeUnretainedValue() as? NSObject,
              let sessionCls = NSClassFromString("WTSession") as? NSObject.Type,
              let allocated = sessionCls.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let initIMP = class_getMethodImplementation(sessionCls, initSel) else { return nil }
        // Type 2 = composition; composition type 10 = the animated inline replace.
        let session = unsafeBitCast(initIMP, to: Init.self)(allocated, initSel, 2, nil).takeRetainedValue() as! NSObject
        session.setValue(10, forKey: "compositionSessionType")

        let box = ContextBox()
        let willBegin = NSSelectorFromString("willBeginWritingToolsSession:requestContexts:")
        typealias WillBegin = @convention(c) (AnyObject, Selector, AnyObject, @escaping @convention(block) (NSArray?) -> Void) -> Void
        guard let willBeginIMP = coordinator.method(for: willBegin) else { return nil }
        unsafeBitCast(willBeginIMP, to: WillBegin.self)(coordinator, willBegin, session) { contexts in
            box.contexts = contexts as? [NSObject] ?? []
        }
        guard await spin(until: { box.contexts != nil }, limit: 1.5), let context = box.contexts?.first else { return nil }

        let didBegin = NSSelectorFromString("didBeginWritingToolsSession:contexts:")
        typealias DidBegin = @convention(c) (AnyObject, Selector, AnyObject, NSArray) -> Void
        guard let didBeginIMP = coordinator.method(for: didBegin) else { return nil }
        unsafeBitCast(didBeginIMP, to: DidBegin.self)(coordinator, didBegin, session, (box.contexts ?? []) as NSArray)
        let contextRange = (context.value(forKey: "range") as? NSValue)?.rangeValue ?? selection
        await spin(0.1)

        // Action 3 ("pondering") is where the coordinator installs its effect view.
        let action = NSSelectorFromString("writingToolsSession:didReceiveAction:")
        typealias Action = @convention(c) (AnyObject, Selector, AnyObject, Int) -> Void
        guard let actionIMP = coordinator.method(for: action) else { return nil }
        unsafeBitCast(actionIMP, to: Action.self)(coordinator, action, session, 3)
        await spin(0.6)

        // Deliver with the paragraph's own attributes, as Writing Tools does.
        let body = variant.longRewrite
            ? (0..<5).map { "Rewritten sentence \($0) that is longer than the original paragraph was." }.joined(separator: " ")
            : "A much shorter rewrite."
        let attributes = tv.textStorage?.attributes(at: selection.location, effectiveRange: nil) ?? [:]
        let deliver = NSSelectorFromString("compositionSession:didReceiveText:replacementRange:inContext:finished:")
        typealias Deliver = @convention(c) (AnyObject, Selector, AnyObject, NSAttributedString, NSRange, AnyObject, Bool) -> Void
        guard let deliverIMP = coordinator.method(for: deliver) else { return nil }
        unsafeBitCast(deliverIMP, to: Deliver.self)(
            coordinator, deliver, session, NSAttributedString(string: body, attributes: attributes), contextRange, context, true
        )

        // The pre-edit viewport snapshot, then the remainder below the new text.
        let key = ObjectIdentifier(tv)
        _ = await spin(until: { (recorder.snapshots[key] ?? []).filter { $0.bands != nil }.count >= 2 }, limit: 1.5)
        let snapshots = recorder.snapshots[key] ?? []

        // Let the animation finish before the session and the window go.
        await spin(1.2)
        let didEnd = NSSelectorFromString("didEndWritingToolsSession:accepted:")
        typealias DidEnd = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
        if let didEndIMP = coordinator.method(for: didEnd) {
            unsafeBitCast(didEndIMP, to: DidEnd.self)(coordinator, didEnd, session, true)
        }
        await spin(1.0)
        withExtendedLifetime(session) {}

        guard snapshots.count >= 2, let before = snapshots.first, let beforeBands = before.bands,
              let remainder = snapshots.last, let bands = remainder.bands else { return nil }
        return report(before: before.lineTops, beforeBands: beforeBands,
                      after: remainder.lineTops, afterBands: bands, height: remainder.rect.height)
    }

    /// The glyph offset is the one shift that puts the most pre-edit line tops onto
    /// pre-edit bands; the remainder must then show each of its lines there.
    private static func report(before: [CGFloat], beforeBands: [CGFloat],
                               after: [CGFloat], afterBands: [CGFloat], height: CGFloat) -> Report {
        var report = Report()
        report.bands = afterBands
        func hits(_ offset: CGFloat) -> Int {
            before.filter { top in beforeBands.contains { abs($0 - (top + offset)) <= 1 } }.count
        }
        let candidates = before.flatMap { top in beforeBands.map { $0 - top } }.filter { $0 >= 0 && $0 <= 12 }
        guard let best = candidates.max(by: { hits($0) < hits($1) }), hits(best) >= 3 else { return report }
        report.inkOffset = best
        report.expectedLineTops = Array(after.filter { $0 + best >= 1 && $0 + best <= height - 30 }.prefix(4))
        report.missingLineTops = report.expectedLineTops.filter { top in
            !afterBands.contains { abs($0 - (top + best)) <= 1.5 }
        }
        return report
    }
}
