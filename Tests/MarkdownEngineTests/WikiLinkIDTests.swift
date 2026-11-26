//
//  WikiLinkIDTests.swift
//  MarkdownEngineTests
//
//  A link keeps its id when the text before it changes in ways that restyle it
//  before its recorded position is brought up to date. Headless.
//

import AppKit
import Testing
@testable import MarkdownEngine

@MainActor
@Suite("Wiki link ids")
struct WikiLinkIDTests {
    private typealias Editor = MarkdownSourceChangeTests.Editor

    private static let anywhere = NSRange(location: NSNotFound, length: 0)

    private func compose(_ steps: [String], at location: Int, in editor: Editor) {
        editor.textView.setSelectedRange(NSRange(location: location, length: 0))
        for marked in steps {
            editor.textView.setMarkedText(
                marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                replacementRange: Self.anywhere)
        }
        editor.textView.insertText(steps.last ?? "", replacementRange: Self.anywhere)
    }

    @Test("A composition before a link keeps the link's id", arguments: 0...6)
    func composition(distance: Int) async {
        let text = "abcdef"
        let editor = Editor("\(text)[[Page|id-1]] and ![[pic|id-2|200]]\n\nnext [[Page|id-3]]\n")
        compose(["k", "か", "かn", "かん", "漢字"], at: text.count - distance, in: editor)
        #expect(editor.source.contains("[[Page|id-1]] and ![[pic|id-2|200]]\n\nnext [[Page|id-3]]"))
        editor.expectInStep()
        await editor.settle()
        #expect(editor.document.text == editor.source)
    }

    @Test("A composition between two links that touch keeps both ids")
    func compositionBetweenLinks() {
        let editor = Editor("[[A|id-1]][[A|id-2]]")
        compose(["か", "漢字漢字"], at: 5, in: editor)
        #expect(editor.source == "[[A|id-1]]漢字漢字[[A|id-2]]")
        editor.expectInStep()
    }

    @Test("Writing Tools before, between and after links keep their ids", arguments: [false, true])
    func writingTools(proofread: Bool) async {
        guard #available(macOS 15.0, *) else { return }
        let editor = Editor("teh fox [[Page|id-1]] jump ![[pic|id-2|200]] ovr\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: (editor.textView.string as NSString).length))
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        editor.coordinator.wtDetectedMode = proofread ? .proofread : .rewrite
        editor.edit(editor.find("teh"), "the quick")
        editor.edit(editor.find("jump"), "jumps")
        editor.edit(editor.find("ovr"), "over it")
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        #expect(editor.source == "the quick fox [[Page|id-1]] jumps ![[pic|id-2|200]] over it\n")
        editor.expectInStep()
        await editor.settle()
        #expect(editor.document.text == editor.source)
    }

    // MARK: - Another link's id

    @Test("A composition doesn't give a link the id of the one that was where it is now")
    func compositionMovesALinkOntoAnother() async {
        for (text, location, expected) in [
            ("[[A]][[B|id-2]] x", 0, "かかかかか[[A]][[B|id-2]] x"),
            ("- [[A]], [[B|id-2]]", 2, "- かかかかかかか[[A]], [[B|id-2]]"),
        ] {
            let editor = Editor(text)
            let marked = String(repeating: "か", count: expected.count - text.count)
            editor.textView.setSelectedRange(NSRange(location: location, length: 0))
            editor.textView.setMarkedText(
                marked, selectedRange: NSRange(location: marked.count, length: 0), replacementRange: Self.anywhere)
            let id = editor.textView.textStorage?.attribute(.wikiLinkID, at: editor.find("A").location, effectiveRange: nil)
            #expect(id == nil, "restyled mid-composition")
            editor.textView.unmarkText()
            #expect(editor.source == expected)
            await editor.settle()
            #expect(editor.document.text == expected)
        }
    }

    @Test("Writing Tools don't give a link the id of the one that was where it is now", arguments: [false, true])
    func writingToolsMoveALinkOntoAnother(proofread: Bool) {
        guard #available(macOS 15.0, *) else { return }
        for (text, from, to, expected) in [
            ("teh [[A]] [[B|id-2]] x\n", "teh", "the quick", "the quick [[A]] [[B|id-2]] x\n"),
            ("teh long text [[A|id-1]] [[B]] x\n", "teh long", "te", "te text [[A|id-1]] [[B]] x\n"),
            ("[[Gone|id-1]] [[Kept]] end\n", "[[Gone]] ", "", "[[Kept]] end\n"),
        ] {
            let editor = Editor(text)
            editor.textView.setSelectedRange(NSRange(location: 0, length: (editor.textView.string as NSString).length))
            editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
            editor.coordinator.wtDetectedMode = proofread ? .proofread : .rewrite
            editor.edit(editor.find(from), to)
            editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
            #expect(editor.source == expected)
        }
    }

    @Test("A link without an id doesn't take the one of a link deleted before it")
    func deletedLink() {
        let editor = Editor("[[A|id-1]][[B]] x")
        editor.edit(editor.find("[[A]]"), "")
        #expect(editor.source == "[[B]] x")
    }

    @Test("Text written over a link's name, and the link after it, don't take its id")
    func inheritedID() {
        guard #available(macOS 15.0, *) else { return }
        let editor = Editor("[[Page|id-1]] and [[Other]] end\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 10))
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        editor.coordinator.wtDetectedMode = .rewrite
        let text = editor.textView.string as NSString
        // Starts inside "Page", so all of it takes the name's attributes.
        editor.edit(NSRange(location: 3, length: text.length - 4), "age]] or [[Other]] fin")
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        #expect(editor.source == "[[Page|id-1]] or [[Other]] fin\n")
    }

    // MARK: - Edits that reach the link

    @Test("Typing over a name's first letter, and a composition cancelled at its start, keep the id")
    func atTheNamesStart() {
        let typed = Editor("ab[[Page|id-1]] z")
        typed.type("漢", at: 4, replacing: 1)
        typed.type("字", at: 5)
        #expect(typed.source == "ab[[漢字age|id-1]] z")
        let cancelled = Editor("ab[[Page|id-1]] z")
        cancelled.textView.setSelectedRange(NSRange(location: 4, length: 0))
        for marked in ["k", "か", "かn", ""] {
            cancelled.textView.setMarkedText(
                marked, selectedRange: NSRange(location: (marked as NSString).length, length: 0),
                replacementRange: Self.anywhere)
        }
        #expect(cancelled.source == "ab[[Page|id-1]] z")
        cancelled.type("q", at: 0)
        #expect(cancelled.source == "qab[[Page|id-1]] z")
    }

    @Test("Writing Tools that write a paragraph back with its link unchanged keep the id", arguments: [false, true])
    func paragraphWrittenBack(proofread: Bool) {
        guard #available(macOS 15.0, *) else { return }
        let editor = Editor("fox [[Page|id-1]] jump\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: (editor.textView.string as NSString).length))
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        editor.coordinator.wtDetectedMode = proofread ? .proofread : .rewrite
        // As plain text, so the name carries nothing.
        editor.edit(NSRange(location: 0, length: (editor.textView.string as NSString).length - 1), "fox [[Page]] jumps")
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        #expect(editor.source == "fox [[Page|id-1]] jumps\n")
    }

    @Test("⌘Z in a Writing Tools session keeps the ids of the text it goes back to")
    func undoInWritingTools() {
        guard #available(macOS 15.0, *) else { return }
        for text in ["teh [[A]] [[B|id-2]] x\n", "teh [[A|id-1]] [[B]] x\n", "teh\n\n| a |\n|---|\n| [[P|id-1]] |\n"] {
            let editor = Editor(text)
            editor.textView.setSelectedRange(NSRange(location: 0, length: (editor.textView.string as NSString).length))
            editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
            editor.coordinator.wtDetectedMode = .rewrite
            editor.edit(editor.find("teh"), "the quick")
            editor.edit(editor.find("the quick"), "teh")
            // What the undo leaves, then Apple's stale accept over it, as on macOS 15.1–26.
            editor.coordinator.wtPostUndoSnapshot = editor.textView.string
            editor.edit(NSRange(location: 0, length: 3), "the quick")
            editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
            #expect(editor.coordinator.lastComputedStorage == text)
        }
    }

    @Test("Undoing a group of edits keeps the ids of the links it moves")
    func undoGroup() {
        let editor = Editor(
            "word [[N0]]\n\n![[N1|id-1]] tailword [[N2|id-2]]x, ![[N3|id-3]]xword [[N4|id-4]] tail\n\n- [[N5]]x\n")
        let window = editor.neverShownWindow()
        window.makeFirstResponder(editor.textView)
        editor.type("", at: 11, replacing: 1)
        editor.type("q", at: 64)
        for _ in 0..<7 { editor.type("漢", at: 28) }
        let undoManager = editor.textView.undoManager
        undoManager?.undo()
        for id in ["![[N1|id-1]]", "[[N2|id-2]]", "![[N3|id-3]]", "[[N4|id-4]]"] {
            #expect(editor.source.contains(id), "\(id) in \(editor.source)")
        }
        editor.expectInStep()
    }

    // MARK: - Links whose name carries nothing

    @Test("A link in code keeps its id through a composition earlier in its paragraph")
    func codeAfterComposition() {
        let editor = Editor("```\nabcdef[[P|id-1]]\n```\n")
        compose(["か", "漢"], at: 8, in: editor)
        #expect(editor.source == "```\nabcd漢ef[[P|id-1]]\n```\n")
    }

    @Test("A link in a table cell keeps its id through Writing Tools earlier in the document")
    func tableCell() {
        guard #available(macOS 15.0, *) else { return }
        let table = "| a | b |\n|---|---|\n| [[P|id-1]] | q |\n"
        let editor = Editor("teh fox\n\n" + table)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 7))
        editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
        editor.coordinator.wtDetectedMode = .rewrite
        editor.edit(editor.find("teh"), "the quick")
        editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
        #expect(editor.source == "the quick fox\n\n" + table)
    }

    // MARK: - At random

    @Test("Every link keeps its own id, or none, through random edits beside links", arguments: [false, true])
    func random(withoutIDs: Bool) async throws {
        guard #available(macOS 15.0, *) else { return }
        struct Random {
            var state: UInt64
            mutating func next(_ bound: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 33) % UInt64(max(1, bound)))
            }
        }
        let link = try NSRegularExpression(pattern: #"\[\[(N\d)(?:\|([^\]]*))?\]\]"#)
        let befores = ["", "word ", "\n\n", "\n\n- ", "\n\n# ", "\n\n> ", " **b** ", ", "]
        let afters = ["", " tail", "x"]
        for seed in 0..<60 {
            var random = Random(state: UInt64(seed) &* 7919 &+ (withoutIDs ? 13 : 17))
            var text = ""
            var ids: [String: String?] = [:]
            for k in 0..<8 {
                let id: String? = withoutIDs && random.next(3) == 0 ? nil : "id-\(k)"
                ids["N\(k)"] = .some(id)
                text += befores[random.next(befores.count)] + (random.next(4) == 0 ? "!" : "")
                    + "[[N\(k)" + (id.map { "|\($0)" } ?? "") + "]]" + afters[random.next(afters.count)]
            }
            let editor = Editor(text + "\n")
            let window = editor.neverShownWindow()
            window.makeFirstResponder(editor.textView)
            func outsideLinks(_ location: Int) -> Bool {
                WikiLinkService.displayLinkRanges(editor.textView.string as NSString).allSatisfy {
                    location <= $0.range.location || location >= NSMaxRange($0.range)
                }
            }
            for step in 0..<25 {
                let length = (editor.textView.string as NSString).length
                var location = random.next(length + 1)
                for _ in 0..<50 where !outsideLinks(location) { location = random.next(length + 1) }
                let operation = random.next(8)
                switch operation {
                case 0:
                    editor.type("q", at: location)
                case 1, 2:
                    let count = 1 + random.next(8)
                    editor.textView.setSelectedRange(NSRange(location: location, length: 0))
                    for i in 1...count {
                        editor.textView.setMarkedText(
                            String(repeating: "か", count: i), selectedRange: NSRange(location: i, length: 0),
                            replacementRange: Self.anywhere)
                    }
                    editor.textView.insertText(String(repeating: "漢", count: count), replacementRange: Self.anywhere)
                case 3:
                    var end = location
                    while end < length, end < location + 4, outsideLinks(end + 1) { end += 1 }
                    if end > location { editor.type("", at: location, replacing: end - location) }
                case 4:
                    if editor.textView.undoManager?.canUndo == true { editor.textView.undoManager?.undo() }
                case 5:
                    if editor.textView.undoManager?.canRedo == true { editor.textView.undoManager?.redo() }
                default:
                    editor.textView.setSelectedRange(NSRange(location: 0, length: length))
                    editor.coordinator.textViewWritingToolsWillBegin(editor.textView)
                    editor.coordinator.wtDetectedMode = random.next(2) == 0 ? .proofread : .rewrite
                    editor.edit(NSRange(location: location, length: 0), String(repeating: "w", count: 1 + random.next(9)))
                    editor.coordinator.textViewWritingToolsDidEnd(editor.textView)
                }
                let source = editor.source as NSString
                var wrong: String?
                for match in link.matches(in: editor.source, range: NSRange(location: 0, length: source.length)) {
                    let name = source.substring(with: match.range(at: 1))
                    let idRange = match.range(at: 2)
                    let id = idRange.location == NSNotFound ? nil : source.substring(with: idRange)
                    if let expected = ids[name], expected != id { wrong = "\(name) has \(id ?? "no id")" }
                }
                #expect(wrong == nil, "seed \(seed), step \(step), operation \(operation)")
                if wrong != nil { break }
            }
            await editor.settle()
        }
    }
}
