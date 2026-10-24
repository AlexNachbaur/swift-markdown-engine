//
//  HTMLBlockStart.swift
//  MarkdownEngine
//
//  The seven start conditions of a CommonMark raw HTML block
//  (spec 0.31.2 §4.6), each with its end condition. Line classification only;
//  `BlockParser` groups the lines.
//

import Foundation

/// How a raw HTML block opens, which decides how it ends.
enum HTMLBlockStart: Int, Hashable, CaseIterable {
    /// `<pre`, `<script`, `<style` or `<textarea` — ends at a line holding
    /// `</pre>`, `</script>`, `</style>` or `</textarea>`.
    case rawText = 1
    /// `<!--` — ends at a line holding `-->`.
    case comment
    /// `<?` — ends at a line holding `?>`.
    case processingInstruction
    /// `<!` and an ASCII letter (`<!DOCTYPE`) — ends at a line holding `>`.
    case declaration
    /// `<![CDATA[` — ends at a line holding `]]>`.
    case cdata
    /// An opening or closing tag from the block-level list (`<div`, `</table`)
    /// — ends before the next blank line.
    case blockTag
    /// Any other complete opening or closing tag alone on its line — ends
    /// before the next blank line, and cannot interrupt a paragraph.
    case completeTag

    static let all = Set(allCases)
    /// Start conditions 1–6: the ones that may interrupt a paragraph.
    static let interruptingParagraph = all.subtracting([.completeTag])

    /// Types 1–5 end at a marker; 6 and 7 end at a blank line.
    var hasEndMarker: Bool { rawValue <= 5 }

    /// Whether `line` satisfies this type's end condition. The opening line
    /// counts too: `<!-- note -->` opens and closes on one line.
    func closes(_ line: String) -> Bool {
        let lower = line.lowercased()
        switch self {
        case .rawText:
            return Self.rawTextNames.contains { lower.contains("</\($0)>") }
        case .comment:
            return lower.contains("-->")
        case .processingInstruction:
            return lower.contains("?>")
        case .declaration:
            return lower.contains(">")
        case .cdata:
            return lower.contains("]]>")
        case .blockTag, .completeTag:
            return false
        }
    }

    /// The start condition `line` satisfies, or nil when it opens no HTML
    /// block. Up to three spaces of indentation are allowed.
    static func classify(_ line: String) -> HTMLBlockStart? {
        var scalars = Substring(line).unicodeScalars[...]
        var indent = 0
        while indent < 3, scalars.first == " " {
            scalars = scalars.dropFirst()
            indent += 1
        }
        guard scalars.first == "<" else { return nil }
        let text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .newlines)
        let lower = text.lowercased()

        if rawTextNames.contains(where: { lower.hasPrefix("<\($0)") && isTagNameEnd(lower, after: $0.count + 1) }) {
            return .rawText
        }
        if lower.hasPrefix("<!--") { return .comment }
        if lower.hasPrefix("<?") { return .processingInstruction }
        if lower.hasPrefix("<![cdata[") { return .cdata }
        if lower.hasPrefix("<!"), let letter = lower.dropFirst(2).unicodeScalars.first, isASCIILetter(letter) {
            return .declaration
        }
        if let name = leadingTagName(lower), blockTagNames.contains(name.name), isBlockTagEnd(lower, after: name.end) {
            return .blockTag
        }
        if isCompleteTagLine(text) { return .completeTag }
        return nil
    }

    // MARK: - Tag names

    static let rawTextNames = ["pre", "script", "style", "textarea"]

    /// The block-level names of start condition 6.
    static let blockTagNames: Set<String> = [
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center",
        "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset",
        "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5",
        "h6", "head", "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu",
        "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param", "search", "section",
        "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    /// After `<name` (or `</name`): whitespace, `>`, `/>` or the end of the line.
    private static func isBlockTagEnd(_ lower: String, after index: Int) -> Bool {
        let rest = lower.unicodeScalars.dropFirst(index)
        guard let next = rest.first else { return true }
        if next == " " || next == "\t" || next == ">" { return true }
        return next == "/" && rest.dropFirst().first == ">"
    }

    /// After a raw-text opener (`<pre`): whitespace, `>` or the end of the line.
    private static func isTagNameEnd(_ lower: String, after index: Int) -> Bool {
        guard let next = lower.unicodeScalars.dropFirst(index).first else { return true }
        return next == " " || next == "\t" || next == ">"
    }

    /// The lowercased tag name after `<` or `</`, and the index just past it.
    private static func leadingTagName(_ lower: String) -> (name: String, end: Int)? {
        var scalars = lower.unicodeScalars.dropFirst()   // `<`
        var start = 1
        if scalars.first == "/" {
            scalars = scalars.dropFirst()
            start = 2
        }
        guard let first = scalars.first, isASCIILetter(first) else { return nil }
        let name = scalars.prefix { isASCIILetter($0) || isASCIIDigit($0) || $0 == "-" }
        return (String(String.UnicodeScalarView(name)), start + name.count)
    }

    // MARK: - Complete tags (start condition 7)

    /// A complete opening tag or closing tag, followed only by whitespace.
    static func isCompleteTagLine(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var i = 0
        guard i < scalars.count, scalars[i] == "<" else { return false }
        i += 1
        let closing = i < scalars.count && scalars[i] == "/"
        if closing { i += 1 }
        guard i < scalars.count, isASCIILetter(scalars[i]) else { return false }
        let nameStart = i
        while i < scalars.count, isASCIILetter(scalars[i]) || isASCIIDigit(scalars[i]) || scalars[i] == "-" { i += 1 }
        let name = String(String.UnicodeScalarView(scalars[nameStart..<i])).lowercased()
        // The raw-text names belong to start condition 1, never 7.
        if rawTextNames.contains(name) { return false }

        if closing {
            skipWhitespace(scalars, &i)
        } else {
            // Attributes: whitespace, a name, and an optional `= value`.
            while true {
                let beforeWhitespace = i
                skipWhitespace(scalars, &i)
                guard i > beforeWhitespace, i < scalars.count, isAttributeNameStart(scalars[i]) else {
                    i = beforeWhitespace
                    break
                }
                while i < scalars.count, isAttributeNameChar(scalars[i]) { i += 1 }
                var j = i
                skipWhitespace(scalars, &j)
                if j < scalars.count, scalars[j] == "=" {
                    j += 1
                    skipWhitespace(scalars, &j)
                    guard j < scalars.count, let valueEnd = attributeValueEnd(scalars, from: j) else { return false }
                    i = valueEnd
                }
            }
            skipWhitespace(scalars, &i)
            if i < scalars.count, scalars[i] == "/" { i += 1 }
        }
        guard i < scalars.count, scalars[i] == ">" else { return false }
        i += 1
        // Only whitespace may follow the tag on its line.
        return scalars[i...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The index just past an attribute value starting at `start`: a quoted
    /// value, or an unquoted run without whitespace, quotes, `=`, `<`, `>` or `` ` ``.
    private static func attributeValueEnd(_ scalars: [Unicode.Scalar], from start: Int) -> Int? {
        let first = scalars[start]
        if first == "\"" || first == "'" {
            var i = start + 1
            while i < scalars.count, scalars[i] != first { i += 1 }
            return i < scalars.count ? i + 1 : nil
        }
        var i = start
        while i < scalars.count, !" \t\"'=<>`".unicodeScalars.contains(scalars[i]) { i += 1 }
        return i > start ? i : nil
    }

    private static func skipWhitespace(_ scalars: [Unicode.Scalar], _ i: inout Int) {
        while i < scalars.count, scalars[i] == " " || scalars[i] == "\t" { i += 1 }
    }

    private static func isAttributeNameStart(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || c == "_" || c == ":"
    }

    private static func isAttributeNameChar(_ c: Unicode.Scalar) -> Bool {
        isASCIILetter(c) || isASCIIDigit(c) || c == "_" || c == "." || c == ":" || c == "-"
    }

    private static func isASCIILetter(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    private static func isASCIIDigit(_ c: Unicode.Scalar) -> Bool {
        c >= "0" && c <= "9"
    }
}
