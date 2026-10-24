//
//  MarkdownEditorServices.swift
//  MarkdownEngine
//
//  Created by Luca Chen on 16.03.26.
//
//  Protocols and default implementations for engine-side dependencies.
//
//  The Markdown editor engine resolves wiki-links, syntax highlighting,
//  LaTeX rendering, and embedded image lookup through these protocols.
//  Embedders supply the concrete implementations; the engine never
//  reaches into the host app for any of these concerns.
//

import AppKit
import Foundation

// MARK: - Wiki Links

/// Resolves a wiki-link's display name to a stable storage identifier.
///
/// The engine stores wiki-links as `[[Name|<id>]]` and displays them as
/// `[[Name]]`. The resolver maps a display name (and the range it occupies
/// in the document) to whatever stable identifier the embedder uses for
/// linked content. The identifier is opaque to the engine.
public protocol WikiLinkResolver: Sendable {
    /// Resolve a wiki-link by its visible name.
    ///
    /// - Parameters:
    ///   - displayName: The text inside `[[ ]]` as the user sees it.
    ///   - range: The character range the link occupies in the document.
    /// - Returns: A resolution if the link points at known content; `nil` otherwise.
    func resolve(displayName: String, range: NSRange) -> WikiLinkResolution?

    /// Returns the target's CURRENT display name for a stable id, nil if unknown
    /// (renderer falls back to the stored label).
    func name(forID id: String) -> String?

    /// Coarse fingerprint of the resolver's known targets (typically IDs + names).
    /// A different value triggers a wiki-link restyle, so a rename refreshes link
    /// clickability/display without waiting for the next keystroke.
    func fingerprint() -> AnyHashable
}

public extension WikiLinkResolver {
    func fingerprint() -> AnyHashable { 0 }
    func name(forID id: String) -> String? { nil }
}

/// The result of resolving a wiki-link.
public struct WikiLinkResolution: Sendable, Equatable {
    /// Stable identifier persisted in the storage form `[[Name|<id>]]`.
    public let id: String
    /// Whether the linked target currently exists/is reachable.
    public let exists: Bool

    public init(id: String, exists: Bool) {
        self.id = id
        self.exists = exists
    }
}

/// Default resolver that never resolves anything. Useful when an embedder
/// doesn't ship wiki-link support.
public struct NoOpWikiLinkResolver: WikiLinkResolver {
    public init() {}
    public func resolve(displayName: String, range: NSRange) -> WikiLinkResolution? { nil }
}

// MARK: - Embedded Images

/// Loads an `NSImage` for an `![[...]]` embed reference.
///
/// The engine parses `![[name|optional-id|optional-width]]` into a
/// reference and asks the provider for an image. The provider decides
/// where the image actually lives (filesystem, remote, asset catalog).
public protocol EmbeddedImageProvider: Sendable {
    /// Returns an image for the given reference, or `nil` if no image
    /// is available.
    func image(for reference: EmbeddedImageRequest) -> NSImage?

    /// A coarse fingerprint of the provider's current state. Returning
    /// a different value invalidates the engine's image cache. Embedders
    /// typically combine the IDs of all known images.
    func fingerprint() -> AnyHashable
}

/// What the engine asks an `EmbeddedImageProvider` for.
public struct EmbeddedImageRequest: Sendable, Equatable {
    /// Display name of the embed (the part before any `|`).
    public let name: String
    /// Optional explicit identifier supplied as `![[name|id]]`.
    public let id: String?
    /// Optional explicit width supplied as `![[name|...|width]]`.
    public let requestedWidth: CGFloat?

    public init(name: String, id: String? = nil, requestedWidth: CGFloat? = nil) {
        self.name = name
        self.id = id
        self.requestedWidth = requestedWidth
    }
}

/// Default provider that never returns images.
public struct NoOpEmbeddedImageProvider: EmbeddedImageProvider {
    public init() {}
    public func image(for reference: EmbeddedImageRequest) -> NSImage? { nil }
    public func fingerprint() -> AnyHashable { 0 }
}

// MARK: - Syntax Highlighting

/// Provides code-block font, background color, and syntax highlighting.
public protocol SyntaxHighlighter: Sendable {
    /// Monospace font used for fenced code blocks at the requested size.
    func codeFont(size: CGFloat) -> NSFont

    /// Background color used to fill code-block paragraphs. The engine
    /// also uses this color to detect which fragments are code blocks
    /// when drawing custom backgrounds.
    func backgroundColor() -> NSColor

    /// Highlight `code` written in `language`. Return an attributed string
    /// whose attributes carry per-token foreground colors. Return `nil` if
    /// no highlighting is available for this language.
    func highlight(code: String, language: String?) -> NSAttributedString?

    /// Notification name posted when the highlighter's appearance source
    /// changes (light/dark mode flip, theme switch). The engine subscribes
    /// to this notification so it can invalidate cached attributes.
    /// Return `nil` if the highlighter never changes after construction.
    var appearanceDidChangeNotification: Notification.Name? { get }
}

/// Default highlighter that produces no highlighting and supplies a
/// basic system monospace font on a transparent background.
public struct PlainTextSyntaxHighlighter: SyntaxHighlighter {
    public init() {}

    public func codeFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public func backgroundColor() -> NSColor {
        NSColor.textBackgroundColor.withAlphaComponent(0)
    }

    public func highlight(code: String, language: String?) -> NSAttributedString? {
        nil
    }

    public var appearanceDidChangeNotification: Notification.Name? { nil }
}

// MARK: - LaTeX

/// The typesetting mode of a LaTeX formula.
public enum LatexRenderMode: Hashable, Sendable {
    case inline
    case display
}

/// Renders LaTeX formulas to images.
///
/// The mode-aware overload lets renderers distinguish `$ … $` from `$$ … $$`.
/// Existing renderers remain source-compatible because its default
/// implementation forwards to the original overload.
public protocol LatexRenderer: Sendable {
    /// Render `latex` without an explicit mode.
    /// - Returns: A rendered result, or `nil` if the renderer cannot produce
    ///   an image (unsupported syntax, missing dependency, …).
    func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult?

    /// Render `latex` using the mode implied by its Markdown delimiters:
    /// `.display` for `$$ … $$`, `.inline` for `$ … $`.
    ///
    /// This is the only overload the engine calls.
    func render(latex: String, mode: LatexRenderMode, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult?
}

public extension LatexRenderer {
    /// Mode-unaware renderers keep receiving the same delimiter-free LaTeX.
    func render(latex: String, mode: LatexRenderMode, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? {
        render(latex: latex, fontSize: fontSize, theme: theme)
    }
}

/// Output of a LaTeX render call.
public struct LatexRenderResult: Sendable {
    public let image: NSImage
    public let size: CGSize
    /// Distance from the image's bottom edge to its visual baseline.
    /// Used to align inline math with the surrounding text.
    public let baselineOffset: CGFloat

    public init(image: NSImage, size: CGSize, baselineOffset: CGFloat) {
        self.image = image
        self.size = size
        self.baselineOffset = baselineOffset
    }
}

/// Default renderer that ignores LaTeX entirely. The engine falls back to
/// rendering the source text when this is in use.
public struct NoOpLatexRenderer: LatexRenderer {
    public init() {}
    public func render(latex: String, fontSize: CGFloat, theme: MarkdownEditorTheme) -> LatexRenderResult? { nil }
}

// MARK: - HTML Blocks

/// Renders raw HTML blocks (CommonMark §4.6) as views placed in the text flow.
///
/// Registering an enabled renderer turns on HTML-block recognition. With the
/// default ``NoOpHTMLBlockRenderer``, HTML stays literal text, exactly as
/// before, and documents parse identically.
///
/// The engine owns layout: it hosts one view per block at the text column's
/// width, reserves the block's height in the text flow so the content below
/// moves down, and hides the view while the caret is inside the block so the
/// source can be edited. The renderer only draws: it builds the view and
/// reports the height its content needs, whenever that changes. Content such
/// as a web page lays out asynchronously, so the engine never waits for a
/// height — it reserves the last one reported and restyles the block when a
/// new one arrives. HTML comments render as nothing and get no view.
///
/// The `MarkdownEngineWebKit` product ships a WebKit-based implementation.
public protocol HTMLBlockRenderer: Sendable {
    /// Whether HTML blocks are recognized at all. `false` keeps HTML literal
    /// text; the engine reads it whenever it parses.
    var isEnabled: Bool { get }

    /// Makes the view that draws `block`. The engine sets its frame: the text
    /// column's width, and the height last reported.
    ///
    /// Call `heightDidChange` with the height the content needs at the view's
    /// current width once it is known, and again whenever it changes (an image
    /// loads, the width changes). Calls with an unchanged height are ignored.
    @MainActor
    func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView

    /// Brings a view made by ``makeView(for:heightDidChange:)`` up to date with
    /// `block`, after its HTML, font or theme changed.
    @MainActor
    func update(_ view: NSView, for block: HTMLBlockContent)

    /// Coarse fingerprint of what the renderer draws with, such as the
    /// resources it can read or its stylesheet. When a new configuration
    /// carries a different value, every view is made again, so content that
    /// failed to load before (a folder the user just granted access to) loads.
    func fingerprint() -> AnyHashable
}

public extension HTMLBlockRenderer {
    func fingerprint() -> AnyHashable { 0 }
}

/// What an ``HTMLBlockRenderer`` draws: the block's HTML and the document's
/// body style, so rendered text can match the text around it.
public struct HTMLBlockContent: Sendable {
    /// The block's raw HTML, exactly as written, without the trailing newline.
    public let html: String
    /// PostScript name of the document's body font.
    public let fontName: String
    /// Point size of the document's body font.
    public let fontSize: CGFloat
    /// The editor theme, for text and link colors.
    public let theme: MarkdownEditorTheme

    public init(html: String, fontName: String, fontSize: CGFloat, theme: MarkdownEditorTheme) {
        self.html = html
        self.fontName = fontName
        self.fontSize = fontSize
        self.theme = theme
    }
}

/// Default renderer that leaves HTML-block recognition off, so HTML stays
/// literal text.
public struct NoOpHTMLBlockRenderer: HTMLBlockRenderer {
    public init() {}
    public var isEnabled: Bool { false }
    public func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView {
        NSView()
    }
    public func update(_ view: NSView, for block: HTMLBlockContent) {}
}

// MARK: - Event Bus

/// Optional notification-name bridge that lets the editor communicate with
/// surrounding UI without hard-coding any names of its own.
///
/// The engine observes the request notifications it is configured with and
/// posts the response notifications when supplied. Embedders that don't
/// need cross-view formatting commands simply leave every name `nil`.
public struct MarkdownEditorBus: Sendable {
    /// Posted by the host UI to request the engine apply bold styling.
    public var applyBoldRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply italic styling.
    public var applyItalicRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply a heading level.
    /// Expected `userInfo["level"] as? Int`.
    public var applyHeadingRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply highlight styling.
    public var applyHighlightRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply strikethrough styling.
    public var applyStrikethroughRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply inline code styling.
    public var applyInlineCodeRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply blockquote styling.
    public var applyBlockquoteRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply unordered list styling.
    public var applyUnorderedListRequest: Notification.Name?
    /// Posted by the host UI to request the engine apply ordered list styling.
    public var applyOrderedListRequest: Notification.Name?
    /// Posted by the host UI to insert a Markdown link.
    /// Expected `userInfo["url"] as? String`.
    public var applyLinkRequest: Notification.Name?
    /// Posted by the host UI to insert a fenced code block at the cursor.
    public var applyCodeBlockRequest: Notification.Name?
    /// Posted by the host UI to insert a horizontal rule (`---`) at the cursor.
    public var applyHorizontalRuleRequest: Notification.Name?
    /// Posted by the host UI to insert an image embed.
    /// Expected `userInfo["url"] as? String`.
    public var applyImageRequest: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isBold"] as? Bool`.
    public var selectionBoldDidChange: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isItalic"] as? Bool`.
    public var selectionItalicDidChange: Notification.Name?
    /// Posted by the engine after every selection change with `userInfo["isHighlight"] as? Bool`.
    public var selectionHighlightDidChange: Notification.Name?
    /// Posted by the host UI to scroll an in-document find match into view
    /// and highlight all matches. Expected `userInfo["range"] as? NSRange`,
    /// `userInfo["currentIndex"] as? Int`, `userInfo["allRanges"] as? [NSRange]`.
    public var findScrollToRange: Notification.Name?
    /// Posted by the host UI to clear all in-document find highlights.
    public var findClearHighlights: Notification.Name?
    /// Posted by the host UI to run an in-document find against the engine's OWN displayed
    /// text. Expected `userInfo["query"] as? String`, optional `userInfo["currentIndex"] as? Int`.
    /// The engine matches in DISPLAY coordinates, so highlights land correctly even where the
    /// displayed text differs from the source (e.g. node links rendered shorter than
    /// `[[Name|UUID]]`, LaTeX, images). Preferred over `findScrollToRange`, which trusts
    /// host-computed (source-coordinate) ranges.
    public var findQuery: Notification.Name?
    /// Posted by the engine in response to `findQuery` with `userInfo["count"] as? Int`
    /// (number of matches in the displayed text), so the host can show "x of y".
    public var findResults: Notification.Name?
    /// Posted by the host UI to replace the current find match. Expected
    /// `userInfo["query"] as? String`, `userInfo["replacement"] as? String`,
    /// optional `userInfo["currentIndex"] as? Int`. The engine edits its own
    /// displayed text (with undo), re-highlights the remaining matches, and
    /// posts `findResults` with the new count.
    public var replaceCurrent: Notification.Name?
    /// Posted by the host UI to replace every find match in one undo step.
    /// Expected `userInfo["query"] as? String`, `userInfo["replacement"] as? String`.
    /// The engine posts `findResults` with the count still matching afterward
    /// (non-zero only if the replacement itself contains the query).
    public var replaceAll: Notification.Name?

    public init(
        applyBoldRequest: Notification.Name? = nil,
        applyItalicRequest: Notification.Name? = nil,
        applyHeadingRequest: Notification.Name? = nil,
        applyHighlightRequest: Notification.Name? = nil,
        applyStrikethroughRequest: Notification.Name? = nil,
        applyInlineCodeRequest: Notification.Name? = nil,
        applyBlockquoteRequest: Notification.Name? = nil,
        applyUnorderedListRequest: Notification.Name? = nil,
        applyOrderedListRequest: Notification.Name? = nil,
        applyLinkRequest: Notification.Name? = nil,
        applyCodeBlockRequest: Notification.Name? = nil,
        applyHorizontalRuleRequest: Notification.Name? = nil,
        applyImageRequest: Notification.Name? = nil,
        selectionBoldDidChange: Notification.Name? = nil,
        selectionItalicDidChange: Notification.Name? = nil,
        selectionHighlightDidChange: Notification.Name? = nil,
        findScrollToRange: Notification.Name? = nil,
        findClearHighlights: Notification.Name? = nil,
        findQuery: Notification.Name? = nil,
        findResults: Notification.Name? = nil,
        replaceCurrent: Notification.Name? = nil,
        replaceAll: Notification.Name? = nil
    ) {
        self.applyBoldRequest = applyBoldRequest
        self.applyItalicRequest = applyItalicRequest
        self.applyHeadingRequest = applyHeadingRequest
        self.applyHighlightRequest = applyHighlightRequest
        self.applyStrikethroughRequest = applyStrikethroughRequest
        self.applyInlineCodeRequest = applyInlineCodeRequest
        self.applyBlockquoteRequest = applyBlockquoteRequest
        self.applyUnorderedListRequest = applyUnorderedListRequest
        self.applyOrderedListRequest = applyOrderedListRequest
        self.applyLinkRequest = applyLinkRequest
        self.applyCodeBlockRequest = applyCodeBlockRequest
        self.applyHorizontalRuleRequest = applyHorizontalRuleRequest
        self.applyImageRequest = applyImageRequest
        self.selectionBoldDidChange = selectionBoldDidChange
        self.selectionItalicDidChange = selectionItalicDidChange
        self.selectionHighlightDidChange = selectionHighlightDidChange
        self.findScrollToRange = findScrollToRange
        self.findClearHighlights = findClearHighlights
        self.findQuery = findQuery
        self.findResults = findResults
        self.replaceCurrent = replaceCurrent
        self.replaceAll = replaceAll
    }

    public static let `default` = MarkdownEditorBus()
}

// MARK: - Services Container

/// Bundles every external service the engine needs.
///
/// Held by ``MarkdownEditorConfiguration/services``. The engine reads its
/// dependencies exclusively from this container; embedders inject the
/// implementations they want.
public struct MarkdownEditorServices: Sendable {
    public var wikiLinks: any WikiLinkResolver
    public var images: any EmbeddedImageProvider
    public var syntaxHighlighter: any SyntaxHighlighter
    public var latex: any LatexRenderer
    /// Draws raw HTML blocks; the no-op default keeps HTML literal text.
    public var htmlBlocks: any HTMLBlockRenderer
    public var bus: MarkdownEditorBus

    public init(
        wikiLinks: any WikiLinkResolver = NoOpWikiLinkResolver(),
        images: any EmbeddedImageProvider = NoOpEmbeddedImageProvider(),
        syntaxHighlighter: any SyntaxHighlighter = PlainTextSyntaxHighlighter(),
        latex: any LatexRenderer = NoOpLatexRenderer(),
        htmlBlocks: any HTMLBlockRenderer = NoOpHTMLBlockRenderer(),
        bus: MarkdownEditorBus = .default
    ) {
        self.wikiLinks = wikiLinks
        self.images = images
        self.syntaxHighlighter = syntaxHighlighter
        self.latex = latex
        self.htmlBlocks = htmlBlocks
        self.bus = bus
    }

    public static let `default` = MarkdownEditorServices()
}
