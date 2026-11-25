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
        let document: Document
        var mirror = ""
        /// Since the editor started.
        var changes: [MarkdownSourceChange] = []
        var onChange: ((MarkdownSourceChange) -> Void)?

        @MainActor
        final class Document {
            var text: String
            init(_ text: String) { self.text = text }
        }

        init(_ text: String, raw: Bool = false, configuration: MarkdownEditorConfiguration = .default) {
            _ = NSApplication.shared
            var configuration = configuration
            configuration.rawSourceMode = raw
            let document = Document(text)
            self.document = document
            coordinator = NativeTextViewWrapper(
                text: Binding(get: { document.text }, set: { document.text = $0 }),
                configuration: configuration, documentId: "A"
            ).makeCoordinator()
            textView.configuration = configuration
            textView.isEditable = true
            textView.allowsUndo = true
            textView.delegate = coordinator
            coordinator.textView = textView
            coordinator.onSourceChange = { [weak self] in self?.receive($0) }
            coordinator.attach(handle)
            coordinator.rebuildTextStorageAndStyle(textView, from: text)
        }

        private func receive(_ change: MarkdownSourceChange) {
            if change.origin == .start {
                mirror = ""
                changes = []
            } else {
                changes.append(change)
            }
            apply(change)
            onChange?(change)
        }

        private func apply(_ change: MarkdownSourceChange) {
            let text = NSMutableString(string: mirror)
            var last = Int.max
            for edit in change.edits {
                #expect(NSMaxRange(edit.range) <= last, "edits overlap or are out of order")
                last = edit.range.location
                text.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            mirror = text as String
        }

        /// The source text of what the text view shows, worked out from scratch.
        var source: String {
            if coordinator.configuration.rawSourceMode { return textView.string }
            return WikiLinkService.makeStorageState(
                from: textView.string, existingMetadata: coordinator.wikiLinkMetadata,
                textStorage: textView.textStorage
            ).storage
        }

        /// AppKit registers undo only for a view in a window.
        func neverShownWindow() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(textView)
            return window
        }

        /// Lets the queued write reach the document.
        func settle() async {
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
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

    @Test("Loading a document reports the text it starts with, and nothing else")
    func load() {
        let editor = Editor("# Title\n")
        #expect(editor.mirror == "# Title\n")
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

    @Test("Replace All is one edit for each match", arguments: ["dog", "x", "horses", "do\ng", ""])
    func replaceAll(replacement: String) {
        let editor = Editor("cat and cat\nno match\na cat\n")
        editor.coordinator.handleReplaceAll(Notification(
            name: .init("x"), userInfo: ["query": "cat", "replacement": replacement]))
        #expect(editor.source == "cat and cat\nno match\na cat\n".replacingOccurrences(of: "cat", with: replacement))
        #expect(editor.changes.count == 1)
        #expect(editor.changes.last?.edits == [
            edit(23, 3, replacement), edit(8, 3, replacement), edit(0, 3, replacement),
        ])
        editor.expectInStep()
    }

    @Test("Two replacements accepted before the text view says it changed")
    func twoProposals() {
        let editor = Editor("alpha beta [[Page|Alias]] gamma")
        #expect(editor.textView.shouldChangeText(in: NSRange(location: 0, length: 6), replacementString: ""))
        editor.textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 6), with: "")
        #expect(editor.textView.shouldChangeText(in: NSRange(location: 4, length: 0), replacementString: " alpha"))
        editor.textView.textStorage?.replaceCharacters(in: NSRange(location: 4, length: 0), with: " alpha")
        editor.textView.didChangeText()
        #expect(editor.source == "beta alpha [[Page|Alias]] gamma")
        editor.expectInStep()
    }

    // MARK: - Undo

    @Test("Undo and redo are reported")
    func undo() throws {
        let editor = Editor("hello")
        let window = editor.neverShownWindow()
        defer { window.contentView = nil }
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

    @Test("Marking an empty string over a selection is its deletion")
    func emptyComposition() {
        let editor = Editor("abcd")
        editor.textView.setSelectedRange(NSRange(location: 1, length: 2))
        editor.textView.setMarkedText(
            "", selectedRange: NSRange(location: 0, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.textView.string == "ad")
        editor.expectInStep()
    }

    // MARK: - Writing Tools

    @Test("A Writing Tools session is one change, when it ends", .enabled(if: {
        if #available(macOS 15.0, *) { return true } else { return false }
    }()), arguments: [false, true])
    func writingTools(raw: Bool) async {
        guard #available(macOS 15.0, *) else { return }
        for proofread in [true, false] {
            let editor = Editor("teh quick fox\n\nsecond teh\n", raw: raw)
            editor.onChange = { [weak editor] _ in
                // What a collaborator typed in the meantime, let in at the end.
                editor?.onChange = nil
                editor?.edit(NSRange(location: 0, length: 0), "REMOTE ")
            }
            editor.textView.setSelectedRange(NSRange(location: 0, length: 13))
            editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
            editor.coordinator.wtDetectedMode = proofread ? .proofread : .rewrite
            editor.edit(NSRange(location: 0, length: 3), "the")
            editor.edit(NSRange(location: 4, length: 5), "speedy")
            #expect(editor.changes.isEmpty)
            editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
            #expect(editor.changes.count == 2)
            #expect(editor.changes.first?.edits == [edit(4, 5, "speedy"), edit(1, 2, "he")])
            #expect(editor.mirror == "REMOTE the speedy fox\n\nsecond teh\n")
            editor.expectInStep()
            await editor.settle()
            #expect(editor.document.text == editor.mirror)
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
        #expect(editor.changes.isEmpty, "a start, which the mirror followed")
        #expect(editor.mirror == "another document")
        editor.type("!", at: 16)
        editor.expectInStep()
    }

    @Test("A new value that changed far apart leaves what is between alone")
    func bindingValueFarApart() {
        let lines = (0..<400).map { "line \($0) of the document\n" }
        var new = lines
        new[399] = "line 399 of the changed document\n"
        new.insert("inserted\n", at: 2)
        let editor = Editor(lines.joined())
        editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: new.joined())
        #expect(editor.changes.last?.edits.map(\.range.length) == [0, 0])
        #expect(editor.changes.last?.edits.map(\.replacement) == ["changed ", "inserted\n"])
        editor.expectInStep()
    }

    private func diff(_ old: String, _ new: String) -> [MarkdownSourceEdit] {
        SourceTextDiff.edits(
            from: old.utf16Units, NSRange(location: 0, length: old.utf16.count),
            to: new.utf16Units, NSRange(location: 0, length: new.utf16.count))
    }

    @Test("A change to each of 400 lines is an edit to each", arguments: ["dog", "", "dog\n", "> cat"])
    func everyLine(replacement: String) {
        let old = (0..<400).map { "cat \($0) sat, and another cat sat\n" }.joined()
        let edits = diff(old, old.replacingOccurrences(of: "cat", with: replacement))
        #expect(edits.count == 800)
        #expect(edits.allSatisfy { $0.range.length <= 4 })
    }

    @Test("Marking every line is an insert to each", arguments: ["- ", "> ", "\t"])
    func markEveryLine(marker: String) {
        let lines = (0..<20_000).map { "line \($0) of the document" }
        let edits = diff(lines.joined(separator: "\n"), lines.map { marker + $0 }.joined(separator: "\n"))
        #expect(edits.count == 20_000)
        #expect(edits.allSatisfy { $0.range.length == 0 && $0.replacement == marker })
    }

    @Test("Texts that share little are replaced, not picked apart")
    func unrelatedTexts() {
        func text(_ seed: Int, lines: Int) -> String {
            (0..<lines).map { line in
                (0..<120).map { "\(seed)w\(($0 * 7919 + line * 104_729 + seed) % 9973)" }.joined(separator: " ") + "\n"
            }.joined()
        }
        #expect(diff(text(1, lines: 600), text(2, lines: 600)).count <= 600)
        #expect(diff(text(1, lines: 600), text(2, lines: 500)).count == 1)
        #expect(diff((0..<20_000).map { "o\($0)\n" }.joined(), (0..<30_000).map { "n\($0)\n" }.joined()).count == 1)
        #expect(diff("", text(1, lines: 2)).count == 1)
        #expect(diff(text(1, lines: 2), "").count == 1)
        #expect(diff("", "").isEmpty)
    }

    @Test("Random pairs of texts: the edits lead from one to the other")
    func randomPairs() {
        var state: UInt64 = 42
        func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
        let alphabets = [["a", "b", "\n"], ["word", " ", "\n", "other"], ["👍", "👍🏽", "🇨🇦", "\n", "x"], ["\r\n", "e\u{301}", "é"]]
        for round in 0..<4000 {
            let alphabet = alphabets[round % alphabets.count]
            func text() -> [String] { (0..<next(40)).map { _ in alphabet[next(alphabet.count)] } }
            let old = text()
            var new = next(3) == 0 ? text() : old
            for _ in 0..<next(5) where !new.isEmpty {
                let at = next(new.count)
                switch next(3) {
                case 0: new.remove(at: at)
                case 1: new.insert(alphabet[next(alphabet.count)], at: at)
                default: new[at] = alphabet[next(alphabet.count)]
                }
            }
            let result = NSMutableString(string: old.joined())
            for edit in diff(old.joined(), new.joined()) {
                result.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            guard (result as String).hasSameUTF16(as: new.joined()) else {
                Issue.record("round \(round): \(old.joined().debugDescription) to \(new.joined().debugDescription)")
                return
            }
        }
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

    @Test("Offsets map around a link shown under its target's current name")
    func renamedOffsets() {
        struct Resolver: WikiLinkResolver {
            func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
            func name(forID id: String) -> String? { "Longer" }
        }
        var configuration = MarkdownEditorConfiguration.default
        configuration.services.wikiLinks = Resolver()
        let editor = Editor("a [[Old|x]] b", configuration: configuration)
        #expect(editor.textView.string == "a [[Longer]] b")
        for (display, source) in [(4, 4), (10, 7), (11, 10), (12, 11), (14, 13)] {
            #expect(editor.handle.sourceRange(forDisplayRange: NSRange(location: display, length: 0))
                == NSRange(location: source, length: 0), "display \(display)")
            #expect(editor.handle.displayRange(forSourceRange: NSRange(location: source, length: 0))
                == NSRange(location: display, length: 0), "source \(source)")
        }
        #expect(editor.handle.displayRange(forSourceRange: NSRange(location: 8, length: 0))
            == NSRange(location: 10, length: 0))
        editor.type("q", at: 14)
        editor.expectInStep()
    }

    // MARK: - The document

    @Test("Edits in one event reach the document together, the last of them too", arguments: [false, true])
    func severalEditsInOneEvent(raw: Bool) async {
        let editor = Editor("abc", raw: raw)
        editor.type("x", at: 3)
        editor.edit(NSRange(location: 3, length: 1), "")
        await editor.settle()
        #expect(editor.document.text == "abc")
        editor.type("x", at: 3)
        editor.type("y", at: 4)
        await editor.settle()
        #expect(editor.document.text == "abcxy")
        editor.expectInStep()
    }

    @Test("A handler may undo the edit it is told of")
    func handlerEdits() async {
        let editor = Editor("abc")
        editor.onChange = { [weak editor] _ in
            editor?.onChange = nil
            editor?.edit(NSRange(location: 3, length: 1), "")
        }
        editor.type("x", at: 3)
        editor.expectInStep()
        await editor.settle()
        #expect(editor.document.text == "abc")
    }

    // MARK: - Mounted in SwiftUI

    @MainActor
    final class Model: ObservableObject {
        @Published var text = "abc"
        @Published var fontSize: CGFloat = 16
        @Published var raw = false
        @Published var identity = 0
        @Published var isMounted = true
        @Published var documentId = "A"
        @Published var reports = true
        @Published var unrelated = 0
        @Published var handle = MarkdownEditorHandle()
        var mirror = ""
        var origins: [MarkdownSourceChange.Origin] = []

        func receive(_ change: MarkdownSourceChange) {
            origins.append(change.origin)
            if change.origin == .start { mirror = "" }
            let text = NSMutableString(string: mirror)
            for edit in change.edits { text.replaceCharacters(in: edit.range, with: edit.replacement) }
            mirror = text as String
        }
    }

    struct Host: View {
        @ObservedObject var model: Model
        var body: some View {
            if model.isMounted {
                var configuration = MarkdownEditorConfiguration.default
                let _ = configuration.rawSourceMode = model.raw
                NativeTextViewWrapper(
                    text: $model.text, configuration: configuration, fontSize: model.fontSize,
                    documentId: model.documentId,
                    onSourceChange: model.reports ? { model.receive($0) } : nil, handle: model.handle
                )
                .id(model.identity)
            }
        }
    }

    @MainActor
    final class Mounted {
        let model = Model()
        let window: NSWindow
        let host: NSHostingView<Host>

        init(reports: Bool = true) async {
            _ = NSApplication.shared
            model.reports = reports
            host = NSHostingView(rootView: Host(model: model))
            // Never shown.
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            window.contentView = host
            await settle()
        }

        func settle() async {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        func type(_ text: String) throws {
            let view = try #require(model.handle.textView)
            view.insertText(text, replacementRange: NSRange(location: (view.string as NSString).length, length: 0))
        }

        func expectInStep(sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(model.mirror == model.text, sourceLocation: sourceLocation)
            #expect(model.handle.textView?.string == model.text, sourceLocation: sourceLocation)
            #expect(model.handle.sourceText == model.text, sourceLocation: sourceLocation)
        }
    }

    @Test("A keystroke and another change in one event leave text, document and mirror alike")
    func mountedRaces() async throws {
        for change in ["value", "font", "raw", "delete", "remount"] {
            let editor = await Mounted()
            #expect(editor.model.mirror == "abc")
            #expect(editor.model.origins == [.start])
            try editor.type("x")
            switch change {
            case "value": editor.model.text = "ABC"
            case "font": editor.model.fontSize = 20
            case "raw": editor.model.raw = true
            case "remount": editor.model.identity = 1
            default: editor.model.handle.textView?.deleteBackward(nil)
            }
            editor.host.layoutSubtreeIfNeeded()
            await editor.settle()
            // Forces another pass over the same text.
            editor.model.fontSize += 1
            await editor.settle()
            editor.expectInStep()
            if ["font", "raw", "remount"].contains(change) { #expect(editor.model.text == "abcx", "\(change)") }
            try editor.type("z")
            await editor.settle()
            editor.expectInStep()
        }
    }

    @Test("An edit after a switch of document, in the same event, reaches the new one")
    func editAfterSwitch() async throws {
        let editor = await Mounted()
        try editor.type("x")
        editor.model.documentId = "B"
        editor.model.text = "doc B"
        editor.host.layoutSubtreeIfNeeded()
        try editor.type("y")
        await editor.settle()
        #expect(editor.model.text == "doc By")
        editor.expectInStep()
    }

    @Test("A first handler on a mounted editor is told what it holds")
    func firstHandler() async throws {
        let editor = await Mounted(reports: false)
        try editor.type("x")
        await editor.settle()
        #expect(editor.model.origins.isEmpty)
        editor.model.reports = true
        await editor.settle()
        #expect(editor.model.origins == [.start])
        editor.expectInStep()
        try editor.type("y")
        await editor.settle()
        #expect(editor.model.origins == [.start, .editor])
        editor.expectInStep()
    }

    @Test("Writing Tools that change nothing leave the selection and the composition alone")
    func idleWritingTools() async throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = await Mounted()
        let view = try #require(editor.model.handle.textView as? NativeTextView)
        let coordinator = try #require(editor.model.handle.coordinator)
        view.setSelectedRange(NSRange(location: 1, length: 1))
        coordinator.textViewWritingToolsWillBegin(view)
        coordinator.textViewWritingToolsDidEnd(view)
        await editor.settle()
        #expect(view.selectedRange() == NSRange(location: 1, length: 1))
        view.insertText("Q", replacementRange: NSRange(location: 1, length: 0))
        await editor.settle()
        #expect(view.selectedRange().location == 2)
        view.setMarkedText(
            "か", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.model.unrelated += 1
        await editor.settle()
        #expect(view.hasMarkedText())
        view.unmarkText()
        await editor.settle()
        editor.expectInStep()
    }

    @Test("A Writing Tools result survives an update pass before it reaches the document")
    func writingToolsThenUpdate() async throws {
        guard #available(macOS 15.0, *) else { return }
        for fontChange in [false, true] {
            let editor = await Mounted()
            let view = try #require(editor.model.handle.textView as? NativeTextView)
            let coordinator = try #require(editor.model.handle.coordinator)
            coordinator.textViewWritingToolsWillBegin(view)
            coordinator.wtDetectedMode = .proofread
            #expect(view.shouldChangeText(in: NSRange(location: 0, length: 3), replacementString: "**xyz**"))
            view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 3), with: "**xyz**")
            view.didChangeText()
            if fontChange { editor.model.fontSize = 20 }
            editor.host.layoutSubtreeIfNeeded()
            coordinator.textViewWritingToolsDidEnd(view)
            if fontChange { editor.model.fontSize = 21 }
            editor.host.layoutSubtreeIfNeeded()
            await editor.settle()
            #expect(editor.model.text == "**xyz**")
            editor.expectInStep()
            // The session's text was never styled; the pass after it does that.
            let font = view.textStorage?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont
            #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        }
    }

    @Test("A partly undone Writing Tools session keeps what is left of it")
    func partlyUndoneWritingTools() async throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = await Mounted()
        let view = try #require(editor.model.handle.textView as? NativeTextView)
        let coordinator = try #require(editor.model.handle.coordinator)
        coordinator.textViewWritingToolsWillBegin(view)
        coordinator.wtDetectedMode = .rewrite
        for (range, text) in [(NSRange(location: 0, length: 1), "X"), (NSRange(location: 2, length: 1), "Z")] {
            #expect(view.shouldChangeText(in: range, replacementString: text))
            view.textStorage?.replaceCharacters(in: range, with: text)
            view.didChangeText()
        }
        // What the undo of the second edit leaves, as macOS 15.1–26 hand it over.
        coordinator.wtPostUndoSnapshot = "Xbc"
        coordinator.textViewWritingToolsDidEnd(view)
        await editor.settle()
        editor.model.unrelated += 1
        await editor.settle()
        #expect(editor.model.text == "Xbc")
        editor.expectInStep()
    }

    @Test("A keystroke between a Writing Tools result and the pass that styles it is kept")
    func typingAfterWritingTools() async throws {
        guard #available(macOS 15.0, *) else { return }
        let editor = await Mounted()
        let view = try #require(editor.model.handle.textView as? NativeTextView)
        let coordinator = try #require(editor.model.handle.coordinator)
        coordinator.textViewWritingToolsWillBegin(view)
        coordinator.wtDetectedMode = .proofread
        #expect(view.shouldChangeText(in: NSRange(location: 0, length: 3), replacementString: "xyz"))
        view.textStorage?.replaceCharacters(in: NSRange(location: 0, length: 3), with: "xyz")
        view.didChangeText()
        coordinator.textViewWritingToolsDidEnd(view)
        await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        try editor.type("Q")
        await editor.settle()
        #expect(editor.model.text == "xyzQ")
        editor.expectInStep()
    }

    @Test("A first handler that comes with a switch of document isn't told of the last one")
    func firstHandlerWithSwitch() async throws {
        let editor = await Mounted(reports: false)
        editor.model.documentId = "B"
        editor.model.text = "doc B"
        editor.model.reports = true
        await editor.settle()
        #expect(editor.model.origins == [.start])
        #expect(editor.model.mirror == "doc B")
        editor.expectInStep()
    }

    @Test("The handle refers to the mounted editor only, and unmounting frees it")
    func handleAndUnmount() async throws {
        let editor = await Mounted()
        let first = editor.model.handle
        weak var textView = first.textView
        weak var coordinator = first.coordinator
        #expect(textView != nil)
        editor.model.handle = MarkdownEditorHandle()
        await editor.settle()
        #expect(first.textView == nil)
        #expect(editor.model.handle.textView != nil)
        editor.model.isMounted = false
        await editor.settle()
        #expect(editor.model.handle.textView == nil)
        #expect(editor.model.handle.sourceText == nil)
        for _ in 0..<50 where coordinator != nil { await editor.settle() }
        #expect(coordinator == nil)
    }

    // MARK: - Fuzz

    @Test("2,000 random edits, over every kind of text", arguments: [false, true])
    func fuzz(raw: Bool) async throws {
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
        let window = editor.neverShownWindow()
        defer { window.contentView = nil }
        let undo = try #require(editor.textView.undoManager)
        let whole = NSRange(location: NSNotFound, length: 0)
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
            switch random.next(14) {
            case 0...1: editor.edit(target, replacement)
            case 2 where target.length > 0 && !raw:
                editor.textView.setSelectedRange(target)
                editor.coordinator.didMarkdownBold(nil)
            case 3: if undo.canUndo { undo.undo() }
            case 4: if undo.canRedo { undo.redo() }
            case 5:
                editor.textView.setSelectedRange(target)
                for marked in ["か", "かn", "かん"] {
                    editor.textView.setMarkedText(
                        marked, selectedRange: NSRange(location: 1, length: 0), replacementRange: whole)
                }
                switch random.next(3) {
                case 0: editor.textView.insertText("漢", replacementRange: whole)
                case 1: editor.textView.unmarkText()
                default:
                    editor.textView.setMarkedText(
                        "", selectedRange: NSRange(location: 0, length: 0), replacementRange: whole)
                }
            case 6 where step % 5 == 0:
                editor.coordinator.handleReplaceAll(Notification(
                    name: .init("x"), userInfo: ["query": "a", "replacement": ["b", "", "a\na"][random.next(3)]]))
            case 7 where step % 5 == 0:
                // A value from outside, after which the undo history means nothing.
                undo.removeAllActions()
                editor.document.text = "new\n" + editor.source.replacingOccurrences(of: "word", with: "WORD")
                editor.coordinator.rebuildTextStorageAndStyle(editor.textView, from: editor.document.text)
            default: editor.type(replacement, at: target.location, replacing: target.length)
            }
            guard editor.mirror.hasSameUTF16(as: editor.source) else {
                Issue.record("step \(step): \(editor.changes.last as Any)")
                return
            }
            if step % 20 == 0 {
                // Ends the undo group too, as the end of an event does.
                await editor.settle()
                #expect(editor.document.text.hasSameUTF16(as: editor.mirror), "step \(step)")
            }
            // Deletions win in the long run; keep the text a fair size.
            if editor.textView.string.utf16.count > 6000 {
                editor.edit(NSRange(location: 0, length: editor.textView.string.utf16.count), "a [[Page]] b\n")
            }
        }
        editor.expectInStep()
    }
}
