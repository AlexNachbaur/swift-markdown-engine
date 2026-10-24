//
//  WebKitHTMLBlockRenderer.swift
//  MarkdownEngineWebKit
//
//  Ready-made HTMLBlockRenderer conformance backed by WKWebView.
//

import AppKit
import Foundation
import MarkdownEngine
import UniformTypeIdentifiers
@preconcurrency import WebKit

/// A drop-in ``HTMLBlockRenderer`` that draws each raw HTML block in its own
/// `WKWebView`.
///
/// Each view lays its block out at the text column's width and reports the
/// height its content needs, so the text after the block moves to fit. The
/// report repeats whenever that height changes, for example when an image
/// finishes loading. Text uses the document's body font and the theme's text
/// and link colors, the page background is transparent, and scrolling over a
/// block scrolls the document.
///
/// Relative references such as `<img src="images/fern.png">` resolve against
/// `baseURL`. For a file `baseURL` they are read through `resourceLoader`, so
/// a sandboxed app decides what may be read and how. A remote image needs the
/// `com.apple.security.network.client` entitlement in a sandboxed app.
///
/// Link clicks never navigate a block; they go to `openURL`, which opens them
/// with `NSWorkspace` unless you supply your own handler.
///
/// The block's own JavaScript is off unless `allowsJavaScript` is `true`.
/// Markdown files often come from elsewhere, so leave it off unless you trust
/// the documents.
public final class WebKitHTMLBlockRenderer: HTMLBlockRenderer, @unchecked Sendable {
    /// Reads a resource a block refers to; `nil` when it can't be read.
    public typealias ResourceLoader = @Sendable (URL) -> Data?

    private let baseURL: URL?
    private let schemeHandler: ResourceSchemeHandler
    private let stylesheet: String
    private let allowsJavaScript: Bool
    private let renderFingerprint: AnyHashable
    private let openURL: @MainActor @Sendable (URL) -> Void

    /// - Parameters:
    ///   - baseURL: What relative references resolve against, usually the
    ///     folder holding the document. `nil` leaves them unresolved.
    ///   - resourceLoader: Reads a file a block refers to, given its resolved
    ///     file URL. Runs off the main thread. `nil` reads the file directly,
    ///     which in a sandboxed app works only where the app already has access.
    ///   - stylesheet: CSS appended after the built-in styles, to tune how
    ///     blocks look.
    ///   - allowsJavaScript: Whether a block's own scripts run.
    ///   - fingerprint: Change it when what the renderer can read changes, for
    ///     example after the user grants access to a folder; the editor then
    ///     makes every view again so failed resources load.
    ///   - openURL: Handles a clicked link, given its resolved URL. `nil`
    ///     opens it with `NSWorkspace`.
    public init(
        baseURL: URL? = nil,
        resourceLoader: ResourceLoader? = nil,
        stylesheet: String = "",
        allowsJavaScript: Bool = false,
        fingerprint: AnyHashable = 0,
        openURL: (@MainActor @Sendable (URL) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.schemeHandler = ResourceSchemeHandler(load: resourceLoader ?? { try? Data(contentsOf: $0) })
        self.stylesheet = stylesheet
        self.allowsJavaScript = allowsJavaScript
        self.renderFingerprint = fingerprint
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    public var isEnabled: Bool { true }

    public func fingerprint() -> AnyHashable {
        [renderFingerprint, AnyHashable(baseURL), AnyHashable(stylesheet), AnyHashable(allowsJavaScript)]
    }

    @MainActor
    public func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: ResourceSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = allowsJavaScript
        configuration.suppressesIncrementalRendering = false

        let heightHandler = HeightMessageHandler(heightDidChange)
        let controller = configuration.userContentController
        controller.add(heightHandler, contentWorld: .defaultClient, name: HeightMessageHandler.name)
        controller.addUserScript(WKUserScript(
            source: HTMLBlockDocument.heightScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))

        let navigation = NavigationPolicy(openURL: openURL, documentBaseURL: baseURL)
        let webView = HTMLBlockWebView(frame: .zero, configuration: configuration, navigation: navigation)
        webView.load(block, stylesheet: stylesheet, baseURL: baseURL)
        return webView
    }

    @MainActor
    public func update(_ view: NSView, for block: HTMLBlockContent) {
        guard let webView = view as? HTMLBlockWebView else { return }
        webView.load(block, stylesheet: stylesheet, baseURL: baseURL)
    }
}

// MARK: - Web view

/// A web view that lets the document scroll over it, draws no background of
/// its own, and follows the editor's light or dark appearance.
final class HTMLBlockWebView: WKWebView {
    // `navigationDelegate` is weak; the view keeps its policy alive.
    private let navigation: NavigationPolicy
    private var block: HTMLBlockContent?

    init(frame: NSRect, configuration: WKWebViewConfiguration, navigation: NavigationPolicy) {
        self.navigation = navigation
        super.init(frame: frame, configuration: configuration)
        navigationDelegate = navigation
        allowsMagnification = false
        allowsBackForwardNavigationGestures = false
        // There is no public switch for a transparent WKWebView on macOS. This
        // key is the long-standing way to get one; without it the view paints
        // white over the editor's background.
        setValue(false, forKey: "drawsBackground")
        underPageBackgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    func load(_ block: HTMLBlockContent, stylesheet: String, baseURL: URL?) {
        self.block = block
        let page = HTMLBlockDocument.page(
            for: block,
            colors: HTMLBlockDocument.colorRules(for: block.theme, appearance: effectiveAppearance),
            stylesheet: stylesheet
        )
        loadHTMLString(page, baseURL: ResourceSchemeHandler.pageBaseURL(for: baseURL))
    }

    /// The block fits its content, so there is nothing to scroll inside it.
    override func scrollWheel(with event: NSEvent) {
        if let superview {
            superview.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let block else { return }
        let rules = HTMLBlockDocument.colorRules(for: block.theme, appearance: effectiveAppearance)
        let script = "document.getElementById('\(HTMLBlockDocument.colorStyleID)').textContent = \(HTMLBlockDocument.javaScriptString(rules));"
        evaluateJavaScript(script, in: nil, in: .defaultClient, completionHandler: nil)
    }
}

// MARK: - Page

/// Builds the page a block is shown in.
enum HTMLBlockDocument {
    static let colorStyleID = "markdown-engine-colors"

    /// Reports the body's height now, on load, and whenever it changes. The
    /// body contains its children's margins (`flow-root`), so its height is
    /// the content's.
    static let heightScript = """
    (() => {
      const post = () => window.webkit.messageHandlers.\(HeightMessageHandler.name)
        .postMessage(Math.ceil(document.body.getBoundingClientRect().height));
      new ResizeObserver(post).observe(document.body);
      window.addEventListener('load', post);
      post();
    })();
    """

    static func page(for block: HTMLBlockContent, colors: String, stylesheet: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <style id="\(colorStyleID)">\(colors)</style>
        <style>
        :root { color-scheme: light dark; }
        html, body { margin: 0; padding: 0; background: transparent; overflow: hidden; }
        body {
          display: flow-root;
          font-family: \(cssFontFamily(block.fontName));
          font-size: \(cssNumber(block.fontSize))px;
          line-height: 1.4;
          color: var(--markdown-engine-text);
          overflow-wrap: break-word;
          -webkit-user-select: text;
        }
        body > :first-child { margin-top: 0; }
        body > :last-child { margin-bottom: 0; }
        a { color: var(--markdown-engine-link); }
        img, video, svg, iframe { max-width: 100%; }
        \(stylesheet)
        </style>
        </head><body>
        \(block.html)
        </body></html>
        """
    }

    /// The theme's text and link colors as CSS variables, resolved for
    /// `appearance` (theme colors may be dynamic system colors).
    static func colorRules(for theme: MarkdownEditorTheme, appearance: NSAppearance) -> String {
        var text = ""
        var link = ""
        appearance.performAsCurrentDrawingAppearance {
            text = cssColor(theme.bodyText)
            link = cssColor(theme.link)
        }
        return ":root { --markdown-engine-text: \(text); --markdown-engine-link: \(link); }"
    }

    /// A CSS `font-family` value for a PostScript font name. System fonts
    /// have private names (`.SFNS-Regular`) that CSS can't name, so they map
    /// to the system font family.
    static func cssFontFamily(_ fontName: String) -> String {
        if fontName.hasPrefix(".") { return "-apple-system, system-ui, sans-serif" }
        let family = NSFont(name: fontName, size: 12)?.familyName ?? fontName
        let escaped = family.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\", -apple-system, system-ui, sans-serif"
    }

    static func cssColor(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "CanvasText" }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return "rgba(\(channel(rgb.redComponent)), \(channel(rgb.greenComponent)), \(channel(rgb.blueComponent)), \(cssNumber(rgb.alphaComponent)))"
    }

    static func cssNumber(_ value: CGFloat) -> String {
        String(format: "%.3f", Double(value))
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    /// `value` as a JavaScript string literal.
    static func javaScriptString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - Height reports

final class HeightMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "markdownEngineHeight"
    private let heightDidChange: @MainActor (CGFloat) -> Void

    init(_ heightDidChange: @escaping @MainActor (CGFloat) -> Void) {
        self.heightDidChange = heightDidChange
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let number = message.body as? NSNumber else { return }
        let height = CGFloat(number.doubleValue)
        MainActor.assumeIsolated { heightDidChange(height) }
    }
}

// MARK: - Links

/// Lets a block load once, then sends every link click to `openURL` instead
/// of navigating the block. Embedded frames (a video player) load normally.
final class NavigationPolicy: NSObject, WKNavigationDelegate {
    private let openURL: @MainActor @Sendable (URL) -> Void
    private let documentBaseURL: URL?

    init(openURL: @escaping @MainActor @Sendable (URL) -> Void, documentBaseURL: URL?) {
        self.openURL = openURL
        self.documentBaseURL = documentBaseURL
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // A link with no target frame opens a new window: treat it as the main frame's.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame else {
            decisionHandler(.allow)
            return
        }
        let url = navigationAction.request.url
        guard navigationAction.navigationType == .linkActivated else {
            // Only the block's own page loads in the main frame; a redirect,
            // a meta refresh or a form never replaces it.
            let isPageLoad = url.map { Self.isSamePage($0, as: Self.pageURL(for: documentBaseURL)) } ?? false
            decisionHandler(isPageLoad ? .allow : .cancel)
            return
        }
        decisionHandler(.cancel)
        guard let url else { return }
        // A same-page anchor has nowhere to go in a block that fits its content.
        if url.fragment != nil, let current = webView.url, Self.isSamePage(url, as: current) { return }
        openURL(ResourceSchemeHandler.fileURL(for: url) ?? url)
    }

    /// The URL a block's page loads at.
    static func pageURL(for baseURL: URL?) -> URL {
        ResourceSchemeHandler.pageBaseURL(for: baseURL) ?? URL(string: "about:blank")!
    }

    /// Whether `url` is `page`, ignoring any fragment.
    static func isSamePage(_ url: URL, as page: URL) -> Bool {
        var target = URLComponents(url: url, resolvingAgainstBaseURL: true)
        var current = URLComponents(url: page, resolvingAgainstBaseURL: true)
        target?.fragment = nil
        current?.fragment = nil
        return target == current
    }
}

// MARK: - Resources

/// Serves a block's relative file references through the embedder's loader.
///
/// A block's page loads from `markdown-engine-resource://file/<folder>/`, so a
/// relative reference resolves the way it would against the folder itself,
/// `../` included; the handler turns the request back into a file URL.
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "markdown-engine-resource"
    private static let host = "file"

    private let load: WebKitHTMLBlockRenderer.ResourceLoader
    /// Tasks WebKit hasn't stopped; a stopped task must not be answered.
    @MainActor private var activeTasks: Set<ObjectIdentifier> = []

    init(load: @escaping WebKitHTMLBlockRenderer.ResourceLoader) {
        self.load = load
    }

    /// The URL a block's page loads from. A file base becomes a folder URL in
    /// this scheme; any other base is used as is.
    static func pageBaseURL(for baseURL: URL?) -> URL? {
        guard let baseURL else { return nil }
        guard baseURL.isFileURL else { return baseURL }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        let path = baseURL.standardizedFileURL.path
        components.path = path.hasSuffix("/") ? path : path + "/"
        return components.url
    }

    /// The file a URL in this scheme stands for, or `nil` for any other URL.
    static func fileURL(for url: URL) -> URL? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let file = URL(fileURLWithPath: url.path)
        guard let fragment = url.fragment,
              var components = URLComponents(url: file, resolvingAgainstBaseURL: false) else { return file }
        components.fragment = fragment
        return components.url ?? file
    }

    static func mimeType(for url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    @MainActor
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let requestURL = task.request.url, let file = Self.fileURL(for: requestURL) else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        // The pending closure holds the task, so its identifier can't be
        // reused by another task until it is answered.
        let pending = PendingTask(task: task)
        activeTasks.insert(pending.id)
        let load = self.load
        DispatchQueue.global(qos: .userInitiated).async {
            let data = load(file)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.answer(pending, url: requestURL, file: file, data: data)
                }
            }
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    @MainActor
    private func answer(_ pending: PendingTask, url: URL, file: URL, data: Data?) {
        guard activeTasks.remove(pending.id) != nil else { return }
        let task = pending.task
        guard let data else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = Self.mimeType(for: file)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mimeType, "Content-Length": String(data.count)]
        ) ?? URLResponse(url: url, mimeType: mimeType, expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    /// A scheme task in flight. WebKit hands tasks over on the main thread and
    /// they are only touched there; the loader runs elsewhere without them.
    private struct PendingTask: @unchecked Sendable {
        let task: any WKURLSchemeTask
        var id: ObjectIdentifier { ObjectIdentifier(task) }
    }
}
