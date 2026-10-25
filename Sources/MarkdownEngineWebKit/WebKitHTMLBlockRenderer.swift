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
///
/// Remote content (images, frames, fonts and styles from the web) loads unless
/// `allowsRemoteContent` is `false`. Loading it tells the server that the
/// document was opened, so an app may want to ask first: with remote content
/// off, `onBlockedRemoteContent` reports each URL a block was kept from loading.
public final class WebKitHTMLBlockRenderer: HTMLBlockRenderer, @unchecked Sendable {
    /// Reads a resource a block refers to; `nil` when it can't be read.
    public typealias ResourceLoader = @Sendable (URL) -> Data?

    private let baseURL: URL?
    private let schemeHandler: ResourceSchemeHandler
    private let stylesheet: String
    private let allowsJavaScript: Bool
    private let allowsRemoteContent: Bool
    private let onBlockedRemoteContent: (@MainActor @Sendable (URL) -> Void)?
    private let renderFingerprint: AnyHashable
    private let openURL: @MainActor @Sendable (URL) -> Void

    /// - Parameters:
    ///   - baseURL: What relative references resolve against, usually the
    ///     folder holding the document. `nil` leaves them unresolved.
    ///   - resourceLoader: Reads a file a block refers to, given its resolved
    ///     file URL. Runs off the main thread. It is asked for every file a block
    ///     names, including ones outside `baseURL` (`../`) and, when scripts
    ///     run, ones a script fetches, so it decides what a document may read.
    ///     `nil` reads files directly, only inside `baseURL`'s folder; in a
    ///     sandboxed app that works only where the app already has access.
    ///   - stylesheet: CSS appended after the built-in styles, to tune how
    ///     blocks look.
    ///   - allowsJavaScript: Whether a block's own scripts run.
    ///   - allowsRemoteContent: Whether a block may load anything from the web.
    ///     `false` keeps every load to the block's own files and inline data:
    ///     a content rule list blocks every `http` and `https` request, and a
    ///     Content-Security-Policy on the block's page and on every local file
    ///     it loads reports what was blocked. DNS prefetching is off. Link
    ///     clicks still go to `openURL`.
    ///   - onBlockedRemoteContent: Called with each remote URL a block was kept
    ///     from loading, once per URL per page, while `allowsRemoteContent` is
    ///     `false`. As in CSP violation reports, some loads (frames) report
    ///     only the URL's origin, and a few (`<object>`, `<embed>`, prefetch
    ///     links) are blocked without a report.
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
        allowsRemoteContent: Bool = true,
        onBlockedRemoteContent: (@MainActor @Sendable (URL) -> Void)? = nil,
        fingerprint: AnyHashable = 0,
        openURL: (@MainActor @Sendable (URL) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.schemeHandler = ResourceSchemeHandler(
            load: resourceLoader ?? Self.folderReader(for: baseURL),
            contentSecurityPolicy: allowsRemoteContent ? nil : HTMLBlockDocument.localOnlyPolicy
        )
        self.stylesheet = stylesheet
        self.allowsJavaScript = allowsJavaScript
        self.allowsRemoteContent = allowsRemoteContent
        self.onBlockedRemoteContent = onBlockedRemoteContent
        self.renderFingerprint = fingerprint
        self.openURL = openURL ?? { NSWorkspace.shared.open($0) }
    }

    /// The default loader: reads a file only when it lies inside `baseURL`'s
    /// folder, so a document can't name its way to files elsewhere.
    static func folderReader(for baseURL: URL?) -> ResourceLoader {
        let folder = baseURL.flatMap { $0.isFileURL ? $0.standardizedFileURL.path : nil }
        return { file in
            guard let folder, isFile(file, inside: folder) else { return nil }
            return try? Data(contentsOf: file)
        }
    }

    static func isFile(_ file: URL, inside folder: String) -> Bool {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return file.standardizedFileURL.path.hasPrefix(prefix)
    }

    /// Always `true`: registering this renderer is what turns HTML blocks on.
    public var isEnabled: Bool { true }

    /// Changes with the `fingerprint` passed at init, the base URL, the
    /// stylesheet, and the JavaScript and remote-content switches.
    public func fingerprint() -> AnyHashable {
        [
            renderFingerprint, AnyHashable(baseURL), AnyHashable(stylesheet),
            AnyHashable(allowsJavaScript), AnyHashable(allowsRemoteContent),
        ]
    }

    /// Makes a web view showing `block`; see ``HTMLBlockRenderer/makeView(for:heightDidChange:)``.
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
        if !allowsRemoteContent {
            // Violations fire while the body parses, so listen from the start,
            // in frames too: a local page in a frame carries the same policy.
            let blockedHandler = BlockedContentMessageHandler(onBlockedRemoteContent)
            controller.add(blockedHandler, contentWorld: .defaultClient, name: BlockedContentMessageHandler.name)
            controller.addUserScript(WKUserScript(
                source: HTMLBlockDocument.blockedContentScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: .defaultClient
            ))
        }

        let navigation = NavigationPolicy(openURL: openURL, documentBaseURL: baseURL)
        let webView = HTMLBlockWebView(frame: .zero, configuration: configuration, navigation: navigation)
        let page = pageOptions
        if allowsRemoteContent {
            webView.load(block, page: page)
        } else {
            // The policy in the page doesn't govern everything (`preconnect`
            // opens a connection regardless), so a content rule list blocks
            // every web request as well. It compiles once, asynchronously;
            // the page waits for it.
            RemoteContentRuleList.whenReady { ruleList in
                if let ruleList { controller.add(ruleList) }
                webView.load(block, page: page)
            }
        }
        return webView
    }

    /// Reloads `view` with `block`'s HTML, font and theme.
    @MainActor
    public func update(_ view: NSView, for block: HTMLBlockContent) {
        guard let webView = view as? HTMLBlockWebView else { return }
        webView.load(block, page: pageOptions)
    }

    private var pageOptions: HTMLBlockPageOptions {
        HTMLBlockPageOptions(stylesheet: stylesheet, baseURL: baseURL, allowsRemoteContent: allowsRemoteContent)
    }
}

/// A content rule list blocking every `http` and `https` request, compiled
/// once for the process. If compiling fails, blocks still get the page's
/// Content-Security-Policy.
@MainActor
enum RemoteContentRuleList {
    static let identifier = "MarkdownEngineWebKit.blockRemoteContent"
    static let source = #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#

    private enum State {
        case idle
        case compiling([@MainActor (WKContentRuleList?) -> Void])
        case ready(WKContentRuleList?)
    }

    private static var state = State.idle

    /// Calls `body` with the compiled list (or `nil` if it couldn't be
    /// compiled), right away once it is ready.
    static func whenReady(_ body: @escaping @MainActor (WKContentRuleList?) -> Void) {
        switch state {
        case .ready(let ruleList):
            body(ruleList)
        case .compiling(var waiting):
            waiting.append(body)
            state = .compiling(waiting)
        case .idle:
            state = .compiling([body])
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier,
                encodedContentRuleList: source
            ) { ruleList, _ in
                Task { @MainActor in finish(with: ruleList) }
            }
        }
    }

    private static func finish(with ruleList: WKContentRuleList?) {
        guard case .compiling(let waiting) = state else { return }
        state = .ready(ruleList)
        waiting.forEach { $0(ruleList) }
    }
}

/// What a block's page is built with, beyond the block itself.
struct HTMLBlockPageOptions {
    var stylesheet = ""
    var baseURL: URL?
    var allowsRemoteContent = true
}

// MARK: - Web view

/// A web view that lets the document scroll over it, draws no background of
/// its own, and follows the editor's light or dark appearance.
final class HTMLBlockWebView: WKWebView {
    // `navigationDelegate` is weak; the view keeps its policy alive.
    private let navigation: NavigationPolicy
    private var block: HTMLBlockContent?
    private var page = HTMLBlockPageOptions()

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

    func load(_ block: HTMLBlockContent, page: HTMLBlockPageOptions) {
        self.block = block
        self.page = page
        let html = HTMLBlockDocument.page(
            for: block,
            colors: HTMLBlockDocument.colorRules(for: block.theme, appearance: effectiveAppearance),
            stylesheet: page.stylesheet,
            allowsRemoteContent: page.allowsRemoteContent
        )
        loadHTMLString(html, baseURL: ResourceSchemeHandler.pageBaseURL(for: page.baseURL))
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
        // The page is first loaded before the view joins the editor, with the
        // app's appearance. Until it has loaded there is no style to patch, so
        // load it again with the colors for this appearance.
        guard !isLoading else {
            load(block, page: page)
            return
        }
        let rules = HTMLBlockDocument.colorRules(for: block.theme, appearance: effectiveAppearance)
        let script = """
            const style = document.getElementById('\(HTMLBlockDocument.colorStyleID)');
            if (style) { style.textContent = \(HTMLBlockDocument.javaScriptString(rules)); }
            """
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
    ///
    /// The view is then sized to that height, which changes the viewport, so
    /// content sized by the viewport (`height: 100vh`) would grow with every
    /// report it caused. So when the viewport has just grown to the height
    /// last reported, growth at least as large isn't reported; it becomes the
    /// baseline later changes (an image loading) are measured from. Growth
    /// that comes with any other resize is real and is reported.
    static let heightScript = """
    (() => {
      let lastHeight = -1;
      let lastReported = -1;
      let lastViewport = window.innerHeight;
      const post = () => {
        const height = Math.ceil(document.body.getBoundingClientRect().height);
        const viewport = window.innerHeight;
        const viewportGrowth = viewport - lastViewport;
        const grewToReport = viewportGrowth > 0 && Math.abs(viewport - lastReported) <= 1;
        const followsViewport = grewToReport && height - lastHeight >= viewportGrowth - 1;
        const changed = height !== lastHeight;
        lastViewport = viewport;
        lastHeight = height;
        if (!changed || followsViewport) return;
        lastReported = height;
        window.webkit.messageHandlers.\(HeightMessageHandler.name).postMessage(height);
      };
      new ResizeObserver(post).observe(document.body);
      window.addEventListener('resize', post);
      window.addEventListener('load', post);
      post();
    })();
    """

    /// Keeps every load to the block's own files and inline data. It comes
    /// first in the head, so nothing in the block can load before it applies,
    /// and a policy only ever narrows, so the block can't widen it.
    static let localOnlyPolicy = [
        "default-src 'none'",
        "img-src \(ResourceSchemeHandler.scheme): data: blob:",
        "media-src \(ResourceSchemeHandler.scheme): data: blob:",
        "font-src \(ResourceSchemeHandler.scheme): data:",
        "style-src 'unsafe-inline' \(ResourceSchemeHandler.scheme):",
        "script-src 'unsafe-inline' \(ResourceSchemeHandler.scheme):",
        "frame-src \(ResourceSchemeHandler.scheme):",
        "connect-src \(ResourceSchemeHandler.scheme):",
    ].joined(separator: "; ")

    /// Reports each remote URL the page's policy blocked, once. Runs at
    /// document start: images in the block are blocked while it parses.
    static let blockedContentScript = """
    (() => {
      const reported = new Set();
      document.addEventListener('securitypolicyviolation', (event) => {
        const uri = event.blockedURI;
        if (!/^https?:/i.test(uri) || reported.has(uri)) return;
        reported.add(uri);
        window.webkit.messageHandlers.\(BlockedContentMessageHandler.name).postMessage(uri);
      });
    })();
    """

    static func page(
        for block: HTMLBlockContent,
        colors: String,
        stylesheet: String,
        allowsRemoteContent: Bool = true
    ) -> String {
        // DNS prefetching isn't governed by the policy; switch it off too.
        let policy = allowsRemoteContent
            ? ""
            : """
            <meta http-equiv="Content-Security-Policy" content="\(localOnlyPolicy)">
            <meta http-equiv="x-dns-prefetch-control" content="off">

            """
        return """
        <!doctype html>
        <html><head>
        \(policy)<meta charset="utf-8">
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

/// Relays the remote URLs a block's content policy blocked.
final class BlockedContentMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "markdownEngineBlocked"
    private let onBlocked: (@MainActor @Sendable (URL) -> Void)?

    init(_ onBlocked: (@MainActor @Sendable (URL) -> Void)?) {
        self.onBlocked = onBlocked
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let string = message.body as? String, let url = URL(string: string) else { return }
        MainActor.assumeIsolated { onBlocked?(url) }
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
    /// Sent with every response, so a local page shown in a frame is held to
    /// the same policy as the block's own page.
    private let contentSecurityPolicy: String?
    /// Tasks WebKit hasn't stopped; a stopped task must not be answered.
    @MainActor private var activeTasks: Set<ObjectIdentifier> = []

    init(load: @escaping WebKitHTMLBlockRenderer.ResourceLoader, contentSecurityPolicy: String? = nil) {
        self.load = load
        self.contentSecurityPolicy = contentSecurityPolicy
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
        var headers = ["Content-Type": mimeType, "Content-Length": String(data.count)]
        if let contentSecurityPolicy { headers["Content-Security-Policy"] = contentSecurityPolicy }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
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
