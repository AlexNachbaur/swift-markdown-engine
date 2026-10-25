//
//  HTMLBlockParserTests.swift
//  MarkdownEngineTests
//
//  Raw HTML blocks (CommonMark 0.31.2 §4.6): recognized only when an
//  HTMLBlockRenderer is registered, opaque to inline parsing, and kept exact
//  by the incremental parser.
//

import Foundation
import Testing
@testable import MarkdownEngine

@Suite("HTML blocks — parser")
struct HTMLBlockParserTests {

    private let html = ExtensionRegistry(extensions: [], htmlBlocks: true)

    private func b(_ kind: BlockKind, _ location: Int, _ length: Int) -> Block {
        Block(kind: kind, range: NSRange(location: location, length: length))
    }

    private func kinds(_ text: String, _ registry: ExtensionRegistry) -> [BlockKind] {
        BlockParser.computeBlocks(text, registry: registry).map(\.kind)
    }

    // MARK: Opt-in

    @Test("without a renderer, HTML stays paragraph text")
    func disabledByDefault() {
        let text = "<div>\nhi\n</div>"
        #expect(BlockParser.computeBlocks(text) == [b(.paragraph, 0, 15)])
    }

    @Test("the registry fingerprint is unchanged unless HTML blocks are on")
    func fingerprint() {
        #expect(ExtensionRegistry(extensions: []).fingerprint == "")
        #expect(ExtensionRegistry(extensions: [], htmlBlocks: false).isEmpty)
        #expect(html.fingerprint == "~html")
        #expect(!html.isEmpty)
        let highlight = ExtensionRegistry(extensions: [HighlightExtension()])
        let both = ExtensionRegistry(extensions: [HighlightExtension()], htmlBlocks: true)
        #expect(both.fingerprint == highlight.fingerprint + "~html")
    }

    // MARK: Start and end conditions

    @Test("a block-level tag runs to the next blank line (type 6)")
    func blockTag() {
        let text = "<div class=\"x\">\n*not emphasis*\n</div>\n\nafter"
        #expect(BlockParser.computeBlocks(text, registry: html) == [
            b(.htmlBlock, 0, 38), b(.blank, 38, 1), b(.paragraph, 39, 5),
        ])
    }

    @Test("a one-line block such as <p><img …></p> is a block")
    func oneLineParagraphTag() {
        let text = "<p><img src=\"a.png\" width=\"49%\"><img src=\"b.png\"></p>\n\ntext"
        #expect(kinds(text, html) == [.htmlBlock, .blank, .paragraph])
    }

    @Test("a comment runs to its closing marker, across blank lines (type 2)")
    func multiLineComment() {
        let text = "<!-- one\n\ntwo -->\nafter"
        #expect(BlockParser.computeBlocks(text, registry: html) == [b(.htmlBlock, 0, 18), b(.paragraph, 18, 5)])
    }

    @Test("a comment can open and close on one line")
    func oneLineComment() {
        #expect(kinds("<!-- note -->\ntext", html) == [.htmlBlock, .paragraph])
    }

    @Test("an unclosed comment stays text, like an unclosed fence")
    func unclosedComment() {
        #expect(kinds("<!-- open\nmore text", html) == [.paragraph])
    }

    @Test("<pre> keeps blank lines until </pre> (type 1)")
    func rawText() {
        let text = "<pre>\na\n\nb\n</pre>\nafter"
        #expect(BlockParser.computeBlocks(text, registry: html) == [b(.htmlBlock, 0, 18), b(.paragraph, 18, 5)])
    }

    @Test("processing instructions, declarations and CDATA (types 3–5)")
    func instructionsDeclarationsCDATA() {
        #expect(kinds("<?xml version=\"1.0\"?>", html) == [.htmlBlock])
        #expect(kinds("<!DOCTYPE html>", html) == [.htmlBlock])
        #expect(kinds("<![CDATA[\nx\n]]>", html) == [.htmlBlock])
    }

    @Test("any other complete tag alone on its line opens a block (type 7)")
    func completeTag() {
        #expect(kinds("<span class=\"x\">\nhi", html) == [.htmlBlock])
        #expect(kinds("</custom-element>", html) == [.htmlBlock])
    }

    @Test("types 1–6 interrupt a paragraph; type 7 does not")
    func interruption() {
        #expect(kinds("text\n<div>\nmore", html) == [.paragraph, .htmlBlock])
        #expect(kinds("text\n<!-- c -->", html) == [.paragraph, .htmlBlock])
        #expect(kinds("text\n<span>\nmore", html) == [.paragraph])
    }

    @Test("four spaces of indentation open no block; inline HTML stays in its paragraph")
    func notBlocks() {
        #expect(kinds("    <div>", html) == [.paragraph])
        #expect(kinds("a <b>bold</b> word", html) == [.paragraph])
        #expect(kinds("<b>bold</b> then text", html) == [.paragraph])
    }

    @Test("built-in blocks still classify first")
    func builtinsFirst() {
        #expect(kinds("```\n<div>\n```", html) == [.fencedCode])
    }

    // MARK: Line classification

    @Test("start-condition classification")
    func classify() {
        #expect(HTMLBlockStart.classify("<pre>") == .rawText)
        #expect(HTMLBlockStart.classify("<SCRIPT type=\"x\">") == .rawText)
        #expect(HTMLBlockStart.classify("<prefix>") == .completeTag)
        #expect(HTMLBlockStart.classify("<!-- x") == .comment)
        #expect(HTMLBlockStart.classify("<?php") == .processingInstruction)
        #expect(HTMLBlockStart.classify("<!DOCTYPE html>") == .declaration)
        #expect(HTMLBlockStart.classify("<![CDATA[") == .cdata)
        #expect(HTMLBlockStart.classify("<div") == .blockTag)
        #expect(HTMLBlockStart.classify("</TABLE>") == .blockTag)
        #expect(HTMLBlockStart.classify("<hr/>") == .blockTag)
        #expect(HTMLBlockStart.classify("<divx>") == .completeTag)
        #expect(HTMLBlockStart.classify("   <div>") == .blockTag)
        #expect(HTMLBlockStart.classify("    <div>") == nil)
        #expect(HTMLBlockStart.classify("text <div>") == nil)
        #expect(HTMLBlockStart.classify("<a href=\"x\" title='y' data-z=w disabled>") == .completeTag)
        #expect(HTMLBlockStart.classify("<a href=>") == nil)
        #expect(HTMLBlockStart.classify("<a> trailing text") == nil)
        #expect(HTMLBlockStart.classify("<1>") == nil)
    }

    // MARK: Tokens

    @Test("one token per block, without its line break, and no inline tokens inside")
    func tokens() {
        let text = "<div>\n*x* `y` [[Z]]\n</div>\n\n*after*"
        let tokens = MarkdownTokenizer.parseTokensViaAST(in: text, registry: html)
        let htmlTokens = tokens.filter { $0.kind == .htmlBlock }
        #expect(htmlTokens.count == 1)
        #expect(htmlTokens.first?.range == NSRange(location: 0, length: 26))
        #expect(htmlTokens.first?.markerRanges.isEmpty == true)
        // Only the paragraph after the block carries inline tokens.
        let inline = tokens.filter { $0.kind != .htmlBlock }
        #expect(inline.allSatisfy { $0.range.location >= 28 })
        #expect(inline.contains { $0.kind == .italic })
    }

    // MARK: Incremental parsing

    private static let lineTemplates = [
        "Plain prose with **bold** and *italic* text here.",
        "<div class=\"note\">", "</div>", "<p><img src=\"a.png\"><img src=\"b.png\"></p>",
        "<!-- a comment", "still commenting -->", "<!-- one line -->",
        "<pre>", "code inside", "</pre>", "<span>", "<details><summary>More</summary>",
        "<!DOCTYPE html", "<?php echo 1", "<![CDATA[ raw",
        "# Heading", "- list item", "> quote", "```", "let x = 1", "$$", "",
    ]

    private static let editSnippets = [
        "x", "<", ">", "<!--", "-->", "</div>", "<div>", "</pre>", "\n", "\n\n", "``", "$$", " ",
        "?>", "]]>", "<!DOCTYPE",
    ]

    private struct Rng {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func int(_ upper: Int) -> Int { upper <= 0 ? 0 : Int(next() % UInt64(upper)) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    }

    private func dump(_ tokens: [MarkdownToken]) -> [String] {
        tokens.map { "\($0.kind)|\($0.range)|\($0.contentRange)" }
    }

    @Test(
        "incremental parsing matches a full parse across random edits",
        arguments: [UInt64(0x41), 0x5157, 0xBEEF, 0xC0DE, 0xF00D, 0x7A11]
    )
    func incrementalMatchesFull(seed: UInt64) {
        var rng = Rng(state: seed)
        let state = DocumentParseState()
        var text = (0..<40).map { _ in rng.pick(Self.lineTemplates) }.joined(separator: "\n")
        _ = state.tokens(for: text, edit: nil, registry: html)

        for step in 0..<250 {
            let before = text
            let ns = NSMutableString(string: text)
            let loc = rng.int(ns.length + 1)
            let removeLen = min(rng.int(6), ns.length - loc)
            let insert = rng.int(4) == 0 ? "" : rng.pick(Self.editSnippets)
            ns.replaceCharacters(in: NSRange(location: loc, length: removeLen), with: insert)
            text = ns as String
            let edit = ParseEditDescriptor(
                editedRange: NSRange(location: loc, length: (insert as NSString).length),
                delta: (insert as NSString).length - removeLen
            )
            let incremental = dump(state.tokens(for: text, edit: edit, registry: html))
            let full = dump(MarkdownTokenizer.fullTokens(
                blocks: BlockParser.computeBlocks(text, registry: html),
                ns: text as NSString,
                registry: html
            ))
            #expect(incremental == full, "seed \(seed) step \(step): diverged after inserting \(insert.debugDescription) at \(loc), removing \(removeLen)\nBEFORE:\n\(before.debugDescription)\nAFTER:\n\(text.debugDescription)")
            if incremental != full { return }
        }
    }

    @Test("a > typed far below an unclosed declaration closes it, incrementally too")
    func distantDeclarationClose() {
        let state = DocumentParseState()
        let filler = (0..<12).map { "para \($0)" }.joined(separator: "\n\n")
        let text = "<!DOCTYPE html\n\n\(filler)\n\nalpha beta\n"
        _ = state.tokens(for: text, edit: nil, registry: html)

        let location = (text as NSString).range(of: "alpha ").upperBound
        let edited = (text as NSString).replacingCharacters(in: NSRange(location: location, length: 0), with: ">")
        let edit = ParseEditDescriptor(editedRange: NSRange(location: location, length: 1), delta: 1)
        let incremental = dump(state.tokens(for: edited, edit: edit, registry: html))
        let full = dump(MarkdownTokenizer.fullTokens(
            blocks: BlockParser.computeBlocks(edited, registry: html),
            ns: edited as NSString,
            registry: html
        ))
        #expect(incremental == full)
        #expect(full.contains { $0.hasPrefix("htmlBlock|") })
    }
}
