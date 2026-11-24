//
//  MarkdownSourceChangeTests.swift
//  MarkdownEngineTests
//
//  A mirror built only from the reported changes must always equal the source
//  text, whichever path made the edit. Headless.
//

import AppKit
import SwiftUI
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Source changes")
struct MarkdownSourceChangeTests {

    @MainActor
    final class Editor {
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let handle = MarkdownEditorHandle()
        let coordinator: NativeTextViewCoordinator
        var mirror: String
        var changes: [MarkdownSourceChange] = []

        init(_ text: String, raw: Bool = false, configuration: MarkdownEditorConfiguration = .default) {
            _ = NSApplication.shared
            var configuration = configuration
            configuration.rawSourceMode = raw
            mirror = text
            coordinator = NativeTextViewWrapper(
                text: .constant(text), configuration: configuration, documentId: "A"
            ).makeCoordinator()
            textView.configuration = configuration
            textView.isEditable = true
            textView.allowsUndo = true
            textView.delegate = coordinator
            coordinator.textView = textView
            coordinator.onSourceChange = { [weak self] in self?.receive($0) }
            handle.coordinator = coordinator
            coordinator.rebuildTextStorageAndStyle(textView, from: text)
        }

        private func receive(_ change: MarkdownSourceChange) {
            changes.append(change)
            let text = NSMutableString(string: mirror)
            var last = Int.max
            for edit in change.edits {
                #expect(NSMaxRange(edit.range) <= last, "edits overlap or are out of order")
                last = edit.range.location
                text.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            mirror = text as String
        }

        /// What the engine writes to the binding.
        var source: String {
            coordinator.configuration.rawSourceMode ? textView.string : coordinator.lastComputedStorage
        }

        func expectInStep(_ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(mirror.hasSameUTF16(as: source), comment, sourceLocation: sourceLocation)
            #expect(handle.sourceText?.hasSameUTF16(as: source) == true, comment, sourceLocation: sourceLocation)
        }

        func type(_ text: String, at location: Int, replacing length: Int = 0) {
            textView.setSelectedRange(NSRange(location: location, length: length))
            textView.insertText(text, replacementRange: NSRange(location: location, length: length))
        }

        func edit(_ range: NSRange, _ replacement: String) {
            guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }

        func find(_ text: String) -> NSRange { (textView.string as NSString).range(of: text) }
    }

    private typealias Edit = MarkdownSourceEdit

    private func edit(_ location: Int, _ length: Int, _ replacement: String) -> MarkdownSourceEdit {
        MarkdownSourceEdit(range: NSRange(location: location, length: length), replacement: replacement)
    }

    // MARK: - Typing and smart input

    @Test("Loading a document reports nothing")
    func loadReportsNothing() {
        let editor = Editor("# Title\n")
        #expect(editor.changes.isEmpty)
        editor.expectInStep()
    }

    @Test("A typed character is one edit, where it was typed")
    func typingInARun() {
        let editor = Editor("aaaa")
        editor.type("a", at: 1)
        #expect(editor.changes == [MarkdownSourceChange(edits: [edit(1, 0, "a")], origin: .editor)])
        editor.expectInStep()
    }

    @Test("Deleting one of a run deletes the one that was deleted")
    func deletingInARun() {
        let editor = Editor("aaaa")
        editor.edit(NSRange(location: 2, length: 1), "")
        #expect(editor.changes.last?.edits == [edit(2, 1, "")])
        editor.expectInStep()
    }

    @Test("List continuation, leaving a list, indent and outdent")
    func lists() {
        let editor = Editor("- one")
        editor.type("\n", at: 5)
        editor.expectInStep("continuation")
        #expect(editor.source == "- one\n- ")
        editor.type("two", at: 8)
        editor.expectInStep()
        editor.type("\t", at: 11)
        editor.expectInStep("indent")
        #expect(editor.coordinator.handleBacktab(editor.textView))
        editor.expectInStep("outdent")
        let end = (editor.textView.string as NSString).length
        editor.type("\n", at: end)
        editor.expectInStep()
        editor.type("\n", at: (editor.textView.string as NSString).length)
        editor.expectInStep("empty item")
        #expect(editor.changes.allSatisfy { $0.origin == .editor })
    }

    @Test("Substitutions, pasted text, tables and formulas")
    func smartInput() {
        let editor = Editor("abc - def\n\n| a | b |\n| - | - |\n| 1 | 2 |\n")
        editor.type(">", at: 5)
        #expect(editor.source.hasPrefix("abc → def"))
        editor.expectInStep("arrow")
        editor.type("\n", at: editor.find("1").location + 1)
        editor.expectInStep("table cell newline")
        editor.type("one\r\ntwo\n\n- three\n👩‍👩‍👧 🇨🇦", at: 3)
        editor.expectInStep("paste")
        editor.type("$$x$$", at: 0)
        editor.expectInStep("formula")
    }

    // MARK: - Formatting and find

    @Test("Bold wraps with two inserts and unwraps with two deletes")
    func bold() {
        let editor = Editor("hello world")
        editor.textView.setSelectedRange(NSRange(location: 6, length: 5))
        editor.coordinator.didMarkdownBold(nil)
        #expect(editor.changes.last?.edits == [edit(11, 0, "**"), edit(6, 0, "**")])
        editor.expectInStep()
        editor.textView.setSelectedRange(NSRange(location: 8, length: 5))
        editor.coordinator.didMarkdownBold(nil)
        #expect(editor.source == "hello world")
        #expect(editor.changes.last?.edits == [edit(13, 2, ""), edit(6, 2, "")])
        editor.expectInStep()
    }

    @Test("One replacement that marks three lines is three inserts")
    func markedLines() {
        let editor = Editor("one\ntwo\nthree\n")
        editor.edit(NSRange(location: 0, length: 14), "- one\n- two\n- three\n")
        #expect(editor.changes.last?.edits == [edit(8, 0, "- "), edit(4, 0, "- "), edit(0, 0, "- ")])
        editor.expectInStep()
    }

    @Test("Headings, quotes and code blocks")
    func blocks() {
        let editor = Editor("one\ntwo\n")
        let item = NSMenuItem()
        for level in [1, 3, 2] {
            item.tag = level
            editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            editor.coordinator.didMarkdownHeading(item)
            editor.expectInStep("heading \(level)")
        }
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.coordinator.didMarkdownBlockquote(nil)
        editor.expectInStep("quote")
        editor.textView.setSelectedRange(editor.find("two"))
        editor.coordinator.didMarkdownCodeBlock(nil)
        editor.expectInStep("code block")
    }

    @Test("Marks removed from both ends of a line in one change are two deletes")
    func bodyText() {
        let editor = Editor("intro\n## Title ##\nend")
        let marks = [NSRange(location: 6, length: 3), NSRange(location: 14, length: 3)]
        #expect(editor.textView.shouldChangeText(
            inRanges: marks.map { NSValue(range: $0) }, replacementStrings: ["", ""]))
        editor.textView.textStorage?.beginEditing()
        for mark in marks.reversed() { editor.textView.textStorage?.replaceCharacters(in: mark, with: "") }
        editor.textView.textStorage?.endEditing()
        editor.textView.didChangeText()
        #expect(editor.changes.last?.edits == [edit(14, 3, ""), edit(6, 3, "")])
        editor.expectInStep()
    }

    @Test("Replace All is one edit for each match")
    func replaceAll() {
        let editor = Editor("cat and cat\nno match\na cat\n")
        editor.coordinator.handleReplaceAll(Notification(
            name: .init("x"), userInfo: ["query": "cat", "replacement": "dog"]))
        #expect(editor.source == "dog and dog\nno match\na dog\n")
        #expect(editor.changes.count == 1)
        #expect(editor.changes.last?.edits == [edit(23, 3, "dog"), edit(8, 3, "dog"), edit(0, 3, "dog")])
        editor.expectInStep()
    }

    // MARK: - Undo

    @Test("Undo and redo are reported")
    func undo() throws {
        let editor = Editor("hello")
        // AppKit registers undo only for a view in a window; this one is never shown.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(editor.textView)
        let undo = try #require(editor.textView.undoManager)
        editor.type("!", at: 5)
        editor.textView.breakUndoCoalescing()
        editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
        editor.coordinator.didMarkdownBold(nil)
        editor.expectInStep()
        while undo.canUndo {
            undo.undo()
            #expect(editor.source == editor.textView.string)
            editor.expectInStep("undo")
        }
        #expect(editor.source == "hello")
        while undo.canRedo {
            undo.redo()
            #expect(editor.source == editor.textView.string)
            editor.expectInStep("redo")
        }
        #expect(editor.source == "**hello**!")
    }

    // MARK: - Composition

    @Test("A composition is one edit, when it is committed")
    func composition() {
        let editor = Editor("ab")
        let whole = NSRange(location: NSNotFound, length: 0)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        for marked in ["k", "か", "かn", "かん", "漢"] {
            editor.textView.setMarkedText(marked, selectedRange: NSRange(location: 1, length: 0), replacementRange: whole)
        }
        #expect(editor.changes.isEmpty)
        #expect(editor.handle.sourceRange(forDisplayRange: NSRange(location: 0, length: 1)) == nil)
        editor.textView.insertText("漢", replacementRange: whole)
        #expect(editor.changes == [MarkdownSourceChange(edits: [edit(1, 0, "漢")], origin: .editor)])
        editor.expectInStep()
    }

    @Test("A composition ended in place, without another insert, is reported")
    func unmarkedComposition() {
        let editor = Editor("ab")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.textView.unmarkText()
        #expect(editor.textView.string == "aかb")
        #expect(editor.changes.last?.edits == [edit(1, 0, "か")])
        editor.expectInStep()
    }

    @Test("A composition that is cancelled reports nothing")
    func cancelledComposition() {
        let editor = Editor("ab")
        let whole = NSRange(location: NSNotFound, length: 0)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: whole)
        editor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: whole)
        editor.textView.unmarkText()
        #expect(editor.textView.string == "ab")
        #expect(editor.changes.isEmpty)
        editor.expectInStep()
        #expect(editor.handle.sourceRange(forDisplayRange: NSRange(location: 2, length: 0)) != nil)
    }

    @Test("A composition over a selection, cancelled, is reported as its deletion")
    func cancelledCompositionOverSelection() {
        let editor = Editor("abcd")
        let whole = NSRange(location: NSNotFound, length: 0)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        editor.textView.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: whole)
        editor.textView.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: whole)
        #expect(editor.textView.string == "ad")
        #expect(editor.changes.last?.edits == [edit(1, 2, "")])
        editor.expectInStep()
    }

    // MARK: - Writing Tools

    @Test("A Writing Tools session is one change, when it ends", .enabled(if: {
        if #available(macOS 15.0, *) { return true } else { return false }
    }()))
    func writingTools() {
        guard #available(macOS 15.0, *) else { return }
        for proofread in [true, false] {
            let editor = Editor("teh quick fox\n\nsecond teh\n")
            editor.textView.setSelectedRange(NSRange(location: 0, length: 13))
            editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
            editor.coordinator.wtDetectedMode = proofread ? .proofread : .rewrite
            editor.edit(NSRange(location: 0, length: 3), "the")
            editor.edit(NSRange(location: 4, length: 5), "speedy")
            #expect(editor.changes.isEmpty)
            editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
            #expect(editor.changes.count == 1)
            #expect(editor.mirror == "the speedy fox\n\nsecond teh\n")
            #expect(editor.changes.last?.edits == [edit(4, 5, "speedy"), edit(1, 2, "he")])
        }
    }

    // MARK: - The binding

    @Test("A new value for the same document is reported; a switch of document is not")
    func bindingValue() {
        let editor = Editor("one\ntwo\nthree\n")
        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: "one\n2\nthree\n")
        #expect(editor.changes == [MarkdownSourceChange(edits: [edit(4, 3, "2")], origin: .binding)])
        editor.expectInStep()
        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: "one\n2\nthree\n")
        #expect(editor.changes.count == 1)

        editor.coordinator.documentId = "B"
        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: "another document")
        #expect(editor.changes.count == 1)
        editor.mirror = "another document"
        editor.type("!", at: 16)
        editor.expectInStep()
    }

    @Test("Precomposed and decomposed accents are different text")
    func normalization() {
        let editor = Editor("caf\u{E9}")
        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: "cafe\u{301}")
        #expect(editor.textView.string.hasSameUTF16(as: "cafe\u{301}"))
        #expect(editor.changes.last?.origin == .binding)
        editor.expectInStep()
        editor.edit(NSRange(location: 3, length: 2), "\u{E9}")
        #expect(editor.changes.last?.edits == [edit(3, 2, "\u{E9}")])
        editor.expectInStep()
    }

    @Test("A typed normalization change reaches the binding", arguments: [false, true])
    func normalizationReachesBinding(raw: Bool) async {
        var text = "caf\u{E9}"
        var configuration = MarkdownEditorConfiguration.default
        configuration.rawSourceMode = raw
        let coordinator = NativeTextViewWrapper(
            text: Binding(get: { text }, set: { text = $0 }), configuration: configuration
        ).makeCoordinator()
        _ = NSApplication.shared
        let textView = NativeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.rebuildTextStorageAndStyle(textView, from: text)
        #expect(textView.shouldChangeText(in: NSRange(location: 3, length: 1), replacementString: "e\u{301}"))
        textView.textStorage?.replaceCharacters(in: NSRange(location: 3, length: 1), with: "e\u{301}")
        textView.didChangeText()
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        #expect(text.hasSameUTF16(as: "cafe\u{301}"))
    }

    // MARK: - Source presentation

    @Test("Editing the plain source, and switching to and from it")
    func rawSource() {
        let editor = Editor("see [[Note|abc-123]] now", raw: true)
        editor.type("!", at: 20)
        #expect(editor.changes.last?.edits == [edit(20, 0, "!")])
        editor.expectInStep()
        let count = editor.changes.count
        editor.coordinator.configuration.rawSourceMode = false
        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: editor.mirror)
        #expect(editor.textView.string == "see [[Note]]! now")
        #expect(editor.changes.count == count)
        editor.type("?", at: editor.find("!").location)
        #expect(editor.changes.last?.edits == [edit(20, 0, "?")])
        editor.expectInStep()
    }

    // MARK: - Wiki links

    @Test("Edits before, after and inside a link are in the source's offsets")
    func wikiLinks() {
        let editor = Editor("a [[Page|Alias]] b ![[pic|id-1|200]] c")
        #expect(editor.textView.string == "a [[Page]] b ![[pic]] c")
        editor.type("x", at: 1)
        #expect(editor.changes.last?.edits == [edit(1, 0, "x")])
        editor.expectInStep("before")
        editor.type("y", at: editor.find(" b").location + 2)
        #expect(editor.changes.last?.edits == [edit(19, 0, "y")])
        editor.expectInStep("between")
        editor.type("z", at: editor.find(" c").location + 2)
        editor.expectInStep("after")
        editor.type("s", at: editor.find("Page").location + 4)
        #expect(editor.source.contains("[[Pages|Alias]]"))
        editor.expectInStep("inside")
        editor.edit(editor.find("Pages"), "Q")
        editor.expectInStep("whole name")
        editor.edit(editor.find("]]"), "")
        editor.expectInStep("closing brackets")
        editor.edit(editor.find("![[pic]]"), "")
        editor.expectInStep("whole link")
        editor.type("[[New]]", at: 0)
        editor.expectInStep("new link")
    }

    @Test("An inserted link or embed carries its id")
    func inlineReplacement() {
        let editor = Editor("see [[No]] and [[Page|Alias]]")
        let range = editor.find("[[No]]")
        editor.coordinator.applyInlineReplacement(
            InlineReplacementRequest(
                documentId: "A",
                selection: WikiLinkSelection(displayRange: range, storageRange: nil, placeholder: "No"),
                storageFragment: "[[Note|abc-123]]", isImageEmbedMode: false),
            to: editor.textView)
        #expect(editor.source == "see [[Note|abc-123]] and [[Page|Alias]]")
        editor.expectInStep()
    }

    @Test("Offsets map both ways around links")
    func offsets() throws {
        let editor = Editor("a [[Page|Alias]] b")
        let handle = editor.handle
        for (display, source) in [(0, 0), (2, 2), (4, 4), (8, 8), (9, 15), (10, 16), (12, 18)] {
            #expect(handle.sourceRange(forDisplayRange: NSRange(location: display, length: 0))
                == NSRange(location: source, length: 0), "display \(display)")
            #expect(handle.displayRange(forSourceRange: NSRange(location: source, length: 0))
                == NSRange(location: display, length: 0), "source \(source)")
        }
        #expect(handle.displayRange(forSourceRange: NSRange(location: 11, length: 0)) == NSRange(location: 8, length: 0))
        #expect(handle.sourceRange(forDisplayRange: NSRange(location: 2, length: 8)) == NSRange(location: 2, length: 14))
        #expect(handle.sourceRange(forDisplayRange: NSRange(location: 12, length: 1)) == nil)
        #expect(handle.sourceRange(forDisplayRange: NSRange(location: NSNotFound, length: 0)) == nil)
        #expect(handle.displayRange(forSourceRange: NSRange(location: 19, length: 0)) == nil)
    }

    // MARK: - Fuzz

    @Test("2,000 random edits, over every kind of text", arguments: [false, true])
    func fuzz(raw: Bool) {
        struct Random {
            var state: UInt64
            mutating func next(_ bound: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(max(1, bound)))
            }
        }
        var random = Random(state: raw ? 11 : 7)
        let pieces = [
            "a", "a", "word ", "\n", "\r\n", "- ", "1. ", "> ", "# ", "**", "`", "```\n", "$$", "[[", "]]", "[[Page]]",
            "![[pic]]", "|", "é", "e\u{301}", "漢字", "👩‍👩‍👧", "🇨🇦", "👍🏽", "\t", "->", "| a | b |\n| - | - |\n", " ",
        ]
        let editor = Editor("a [[Page|Alias]] b ![[pic|id-1|200]] c\n\n- [[Other|x]]\n- two [[Third]]\n", raw: raw)
        for step in 0..<2000 {
            let text = editor.textView.string as NSString
            // Whole characters, as a person or AppKit would select.
            let at = text.length == 0 ? 0 : text.rangeOfComposedCharacterSequence(
                at: min(random.next(text.length + 1), text.length - 1)).location
            let span = random.next(3) == 0 ? random.next(12) : 0
            let range = text.length == 0 ? NSRange(location: 0, length: 0)
                : text.rangeOfComposedCharacterSequences(
                    for: NSRange(location: at, length: min(span, text.length - at)))
            let target = NSRange(location: range.location, length: span == 0 ? 0 : range.length)
            let replacement = random.next(4) == 0 ? "" : pieces[random.next(pieces.count)]
            switch random.next(6) {
            case 0: editor.edit(target, replacement)
            case 1 where target.length > 0:
                editor.textView.setSelectedRange(target)
                editor.coordinator.didMarkdownBold(nil)
            default: editor.type(replacement, at: target.location, replacing: target.length)
            }
            guard editor.mirror.hasSameUTF16(as: editor.source) else {
                Issue.record("step \(step): \(editor.changes.last as Any)")
                return
            }
        }
        editor.expectInStep()
    }
}
