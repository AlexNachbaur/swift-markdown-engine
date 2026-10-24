//
//  MarkdownStyler+HTMLBlocks.swift
//  MarkdownEngine
//
//  Raw HTML blocks (CommonMark §4.6), drawn by an embedder-supplied view.
//
//  The styler reserves the block's space the way block LaTeX does — the source
//  collapses to zero width and one anchor character carries a line as tall as
//  the content — but draws nothing itself: the anchor is tagged, and the text
//  view places the renderer's view over the reserved space
//  (`NativeTextView+HTMLBlocks.swift`). The reserved height is whatever that
//  view last reported, read synchronously from `LayoutBridge.htmlBlockHeights`;
//  until a view has reported, one line is reserved.
//

import AppKit
import Foundation

extension NSAttributedString.Key {
    /// Tags the anchor character of a rendered HTML block; the value is an
    /// `HTMLBlockAnchor`. The text view hosts one view per tagged anchor.
    static let htmlBlockAnchor = NSAttributedString.Key("MarkdownEngine.HTMLBlockAnchor")
}

/// What the text view needs to host an HTML block's view: the block's HTML and
/// the body font the styler laid it out with.
final class HTMLBlockAnchor: NSObject {
    let html: String
    let fontName: String
    let fontSize: CGFloat

    init(html: String, fontName: String, fontSize: CGFloat) {
        self.html = html
        self.fontName = fontName
        self.fontSize = fontSize
    }

    // Value equality, so identical runs coalesce when attributes are flattened.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? HTMLBlockAnchor else { return false }
        return html == other.html && fontName == other.fontName && fontSize == other.fontSize
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(fontName)
        hasher.combine(fontSize)
        return hasher.finalize()
    }
}

extension MarkdownStyler {

    static func styleHTMLBlocks(_ ctx: StylingContext) -> [StyledRange] {
        var attrs: [StyledRange] = []
        for (idx, token) in ctx.scoped(ctx.htmlBlockIndexed) {
            // Never spell-check markup, rendered or not.
            attrs.append((token.range, [.spellingState: 0]))

            // Caret inside (or a selection touching it): the source shows as
            // ordinary text so it can be edited.
            if ctx.activeTokenIndices.contains(idx) { continue }

            let html = ctx.nsText.substring(with: token.range)
            if isCommentOnly(html) {
                collapseToNothing(token, ctx: ctx, into: &attrs)
                continue
            }

            let width = availableWidth(ctx)
            let height = ctx.layoutBridge?.htmlBlockHeights[html] ?? ctx.baseDefaultLineHeight
            // A transparent placeholder: the anchor's line takes its size, the
            // fragment draws nothing, and the hosted view covers the space.
            let placeholder = NSImage(size: NSSize(width: width, height: max(height, 1)))
            let anchor = HTMLBlockAnchor(
                html: html,
                fontName: ctx.baseFont.fontName,
                fontSize: ctx.baseFont.pointSize
            )
            _ = appendRenderedStandaloneBlock(
                for: token,
                rawContent: html,
                image: placeholder,
                imageBounds: CGRect(x: 0, y: 0, width: width, height: max(height, 1)),
                paragraphSpacingBefore: ctx.configuration.htmlBlock.paragraphSpacingBefore,
                paragraphSpacing: ctx.configuration.htmlBlock.paragraphSpacing,
                alignment: .left,
                mode: .collapsedSource(markerTexts: []),
                anchorAttributes: [.htmlBlockAnchor: anchor],
                ctx: ctx,
                attrs: &attrs
            )
        }
        return attrs
    }

    /// The text column's usable width, the same measure image embeds use.
    private static func availableWidth(_ ctx: StylingContext) -> CGFloat {
        let style = ctx.configuration.imageEmbed
        if let container = ctx.layoutBridge?.firstTextContainer {
            let width = container.containerSize.width - container.lineFragmentPadding * 2
            if width > 0 && width < style.unreasonableMaxWidth { return width }
        }
        return style.fallbackMaxWidth
    }

    /// True when the block is nothing but HTML comments and whitespace —
    /// what a browser renders as nothing.
    static func isCommentOnly(_ html: String) -> Bool {
        var rest = Substring(html)
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty { return true }
            guard rest.hasPrefix("<!--"), let close = rest.range(of: "-->") else { return false }
            rest = rest[close.upperBound...]
        }
    }

    /// Hides a block entirely: every line collapses to the 1pt minimum the
    /// collapsed-source machinery uses, with clear, zero-width text.
    private static func collapseToNothing(_ token: MarkdownToken, ctx: StylingContext, into attrs: inout [StyledRange]) {
        let collapsed = NSMutableParagraphStyle()
        collapsed.maximumLineHeight = 1
        collapsed.minimumLineHeight = 0
        collapsed.paragraphSpacing = 0
        collapsed.paragraphSpacingBefore = 0
        let paragraphs = ctx.nsText.paragraphRange(for: token.range)
        attrs.append((paragraphs, [.paragraphStyle: collapsed]))
        let text = ctx.nsText.substring(with: token.range)
        attrs.append((token.range, [
            .foregroundColor: NSColor.clear,
            .font: ctx.latexMarkerFont,
            .kern: -hiddenRunKern(text, font: ctx.latexMarkerFont),
        ]))
    }
}
