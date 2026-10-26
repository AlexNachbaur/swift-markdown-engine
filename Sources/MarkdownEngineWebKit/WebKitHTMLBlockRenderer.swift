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
///
/// Web views are reused. Each brings its own WebKit content process, so every
/// renderer in the app, in every window, draws from one shared pool: a view
/// the editor gives back through ``releaseView(_:)`` is kept (up to a few, and
/// none under memory pressure) and handed to the next block that needs one,
/// whichever document it is in. A new web view is made only when the pool has
/// none free. Each use reloads the page with that renderer's resources,
/// scripts and remote-content switch, so nothing carries over between uses
/// but the process. Pooled views keep no cookies or caches on disk.
public final class WebKitHTMLBlockRenderer: HTMLBlockRenderer, @unchecked Sendable {
    /// Reads a resource a block refers to; `nil` when it can't be read.
    public typealias ResourceLoader = @Sendable (URL) -> Data?

    private let baseURL: URL?
    private let resourceLoader: ResourceLoader
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
        self.resourceLoader = resourceLoader ?? Self.folderReader(for: baseURL)
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

    /// Shows `block` in a web view from the shared pool, or a new one when
    /// none is free; see ``HTMLBlockRenderer/makeView(for:heightDidChange:)``.
    @MainActor
    public func makeView(for block: HTMLBlockContent, heightDidChange: @escaping @MainActor (CGFloat) -> Void) -> NSView {
        let webView = HTMLBlockWebViewPool.shared.dequeue()
        webView.begin(
            HTMLBlockLease(
                baseURL: baseURL,
                resourceLoader: resourceLoader,
                stylesheet: stylesheet,
                allowsJavaScript: allowsJavaScript,
                allowsRemoteContent: allowsRemoteContent,
                heightDidChange: heightDidChange,
                onBlockedRemoteContent: onBlockedRemoteContent,
                openURL: openURL
            ),
            showing: block
        )
        return webView
    }

    /// Reloads `view` with `block`'s HTML, font and theme.
    @MainActor
    public func update(_ view: NSView, for block: HTMLBlockContent) {
        guard let webView = view as? HTMLBlockWebView else { return }
        webView.show(block)
    }

    /// Puts `view` back in the shared pool for the next block, in any window.
    @MainActor
    public func releaseView(_ view: NSView) {
        guard let webView = view as? HTMLBlockWebView else { return }
        HTMLBlockWebViewPool.shared.enqueue(webView)
    }

    /// Settled once the page and everything it loads have finished loading.
    @MainActor
    public func hasSettled(_ view: NSView) -> Bool {
        guard let webView = view as? HTMLBlockWebView else { return true }
        return !webView.isLoading && !webView.isWaitingForRuleList
    }
}

/// What one use of a pooled web view draws with: one renderer's resources,
/// scripts and switches, and the callback for one block's height.
@MainActor
final class HTMLBlockLease {
    let baseURL: URL?
    let resourceLoader: WebKitHTMLBlockRenderer.ResourceLoader
    let stylesheet: String
    let allowsJavaScript: Bool
    let allowsRemoteContent: Bool
    let heightDidChange: @MainActor (CGFloat) -> Void
    let onBlockedRemoteContent: (@MainActor @Sendable (URL) -> Void)?
    let openURL: @MainActor @Sendable (URL) -> Void
    /// Names this use. Its resources load under it as the URL host: WebKit
    /// caches loads by URL, so a fresh host per use keeps a reused view from
    /// showing what another document, or an older copy of a file, loaded at
    /// the same path. Its page carries it too, and every message and request
    /// must, so a previous use's page, still alive until the next one
    /// replaces it, can't reach this one.
    let resourceHost = "use-" + UUID().uuidString.lowercased()

    init(
        baseURL: URL?,
        resourceLoader: @escaping WebKitHTMLBlockRenderer.ResourceLoader,
        stylesheet: String,
        allowsJavaScript: Bool,
        allowsRemoteContent: Bool,
        heightDidChange: @escaping @MainActor (CGFloat) -> Void,
        onBlockedRemoteContent: (@MainActor @Sendable (URL) -> Void)?,
        openURL: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        self.baseURL = baseURL
        self.resourceLoader = resourceLoader
        self.stylesheet = stylesheet
        self.allowsJavaScript = allowsJavaScript
        self.allowsRemoteContent = allowsRemoteContent
        self.heightDidChange = heightDidChange
        self.onBlockedRemoteContent = onBlockedRemoteContent
        self.openURL = openURL
    }

    /// Sent with every local file, so a local page shown in a frame is held
    /// to the same policy as the block's own page.
    var contentSecurityPolicy: String? {
        allowsRemoteContent ? nil : HTMLBlockDocument.localOnlyPolicy
    }

    var pageOptions: HTMLBlockPageOptions {
        HTMLBlockPageOptions(
            stylesheet: stylesheet,
            baseURL: baseURL,
            allowsRemoteContent: allowsRemoteContent,
            useToken: resourceHost
        )
    }
}

/// The app-wide reuse pool of block web views, shared by every renderer in
/// every window. A view is made only when none is idle; an idle view is kept
/// up to `idleLimit`, and none are kept under memory pressure.
@MainActor
final class HTMLBlockWebViewPool {
    static let shared = HTMLBlockWebViewPool()

    /// Idle views kept for reuse; any beyond this are let go.
    var idleLimit = 8
    private(set) var idle: [HTMLBlockWebView] = []
    /// Web views made over the pool's life, for measuring reuse.
    private(set) var createdCount = 0
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Pooled views keep cookies and caches in memory only, shared among
    /// them, so nothing a document loads is written to disk.
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.purge() }
        }
        source.resume()
        memoryPressure = source
    }

    /// An idle view, or a new one when none is free.
    func dequeue() -> HTMLBlockWebView {
        if let webView = idle.popLast() { return webView }
        createdCount += 1
        return HTMLBlockWebView(dataStore: dataStore)
    }

    /// Takes a view back: it stops showing its block and waits for the next.
    func enqueue(_ webView: HTMLBlockWebView) {
        webView.end()
        guard !idle.contains(where: { $0 === webView }), idle.count < idleLimit else { return }
        idle.append(webView)
    }

    /// Lets every idle view go, and its content process with it.
    func purge() {
        idle.removeAll()
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
    /// The use the page belongs to; its scripts send it with every message.
    var useToken = ""
}

// MARK: - Web view

/// A web view that lets the document scroll over it, draws no background of
/// its own, and follows the editor's light or dark appearance. It lives in the
/// pool and shows one block per lease; everything a use depends on (the
/// loader, scripts, remote-content switch, height callback) comes from the
/// lease, so the same view can serve any document.
final class HTMLBlockWebView: WKWebView {
    // `navigationDelegate` is weak; the view keeps its policy alive.
    private let navigation = NavigationPolicy()
    private let contentController: WKUserContentController
    /// The current use; `nil` while idle in the pool.
    private(set) var lease: HTMLBlockLease?
    private var block: HTMLBlockContent?

    init(dataStore: WKWebsiteDataStore) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.setURLSchemeHandler(ResourceSchemeHandler.shared, forURLScheme: ResourceSchemeHandler.scheme)
        // Each navigation sets it from the lease (`NavigationPolicy`).
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.suppressesIncrementalRendering = false
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: HTMLBlockDocument.heightScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: .defaultClient
        ))
        // Violations fire while the body parses, so listen from the start, in
        // frames too: a local page in a frame carries the same policy. Without
        // a policy (remote content allowed) there is nothing to report.
        controller.addUserScript(WKUserScript(
            source: HTMLBlockDocument.blockedContentScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false,
            in: .defaultClient
        ))
        contentController = controller
        super.init(frame: .zero, configuration: configuration)
        controller.add(HeightMessageHandler(self), contentWorld: .defaultClient, name: HeightMessageHandler.name)
        controller.add(
            BlockedContentMessageHandler(self),
            contentWorld: .defaultClient,
            name: BlockedContentMessageHandler.name
        )
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

    /// Starts a use: shows `block` with `lease`'s resources and switches.
    func begin(_ lease: HTMLBlockLease, showing block: HTMLBlockContent) {
        self.lease = lease
        contentController.removeAllContentRuleLists()
        guard !lease.allowsRemoteContent else {
            isWaitingForRuleList = false
            show(block)
            return
        }
        // The policy in the page doesn't govern everything (`preconnect`
        // opens a connection regardless), so a content rule list blocks every
        // web request as well. It compiles once, asynchronously; no page
        // loads before it is in, unless the view has moved on to another use.
        self.block = block
        isWaitingForRuleList = true
        RemoteContentRuleList.whenReady { [weak self] ruleList in
            guard let self, self.lease === lease else { return }
            if let ruleList { self.contentController.add(ruleList) }
            self.isWaitingForRuleList = false
            if let block = self.block { self.show(block) }
        }
    }

    /// Set while a use that blocks remote content waits for its rule list;
    /// pages asked for meanwhile load once it is in.
    private(set) var isWaitingForRuleList = false

    /// Ends a use: the block's page goes, and with it its loads and scripts.
    func end() {
        lease = nil
        block = nil
        isWaitingForRuleList = false
        removeFromSuperview()
        stopLoading()
        contentController.removeAllContentRuleLists()
        loadHTMLString("", baseURL: nil)
    }

    /// Loads `block` into the page, with the current lease's options.
    func show(_ block: HTMLBlockContent) {
        guard let lease else { return }
        self.block = block
        guard !isWaitingForRuleList else { return }
        let page = lease.pageOptions
        let html = HTMLBlockDocument.page(
            for: block,
            colors: HTMLBlockDocument.colorRules(for: block.theme, appearance: effectiveAppearance),
            stylesheet: page.stylesheet,
            allowsRemoteContent: page.allowsRemoteContent,
            useToken: page.useToken
        )
        loadHTMLString(html, baseURL: ResourceSchemeHandler.pageBaseURL(for: page.baseURL, host: lease.resourceHost))
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
        guard let block, lease != nil else { return }
        // The page is first loaded before the view joins the editor, with the
        // app's appearance. Until it has loaded there is no style to patch, so
        // load it again with the colors for this appearance.
        guard !isLoading else {
            show(block)
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
        window.webkit.messageHandlers.\(HeightMessageHandler.name).postMessage({ use: \(useTokenExpression), height: height });
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

    /// Names the use a block's page belongs to (a `<meta>` in its head).
    static let useTokenMetaName = "markdown-engine-use"

    /// JavaScript that reads the page's use token, from the top page when run
    /// in a frame (local frames share its origin).
    static let useTokenExpression = """
    (() => { let doc = document; try { doc = window.top.document; } catch (e) {} \
    const meta = doc.querySelector('meta[name="\(useTokenMetaName)"]'); return meta ? meta.content : ''; })()
    """

    /// Reports each remote URL the page's policy blocked, once. Runs at
    /// document start: images in the block are blocked while it parses.
    static let blockedContentScript = """
    (() => {
      const reported = new Set();
      document.addEventListener('securitypolicyviolation', (event) => {
        const uri = event.blockedURI;
        if (!/^https?:/i.test(uri) || reported.has(uri)) return;
        reported.add(uri);
        window.webkit.messageHandlers.\(BlockedContentMessageHandler.name).postMessage({ use: \(useTokenExpression), url: uri });
      });
    })();
    """

    static func page(
        for block: HTMLBlockContent,
        colors: String,
        stylesheet: String,
        allowsRemoteContent: Bool = true,
        useToken: String = ""
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
        <meta name="\(useTokenMetaName)" content="\(useToken)">
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

/// Relays a page's height reports to the current lease. Holds its view weakly:
/// the view's content controller holds the handler.
final class HeightMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "markdownEngineHeight"
    private weak var webView: HTMLBlockWebView?

    init(_ webView: HTMLBlockWebView) {
        self.webView = webView
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let use = body["use"] as? String,
              let number = body["height"] as? NSNumber else { return }
        let height = CGFloat(number.doubleValue)
        MainActor.assumeIsolated {
            // A previous use's page may still report until the next one replaces it.
            guard let lease = webView?.lease, lease.resourceHost == use else { return }
            lease.heightDidChange(height)
        }
    }
}

/// Relays the remote URLs a block's content policy blocked to the current lease.
final class BlockedContentMessageHandler: NSObject, WKScriptMessageHandler {
    static let name = "markdownEngineBlocked"
    private weak var webView: HTMLBlockWebView?

    init(_ webView: HTMLBlockWebView) {
        self.webView = webView
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let use = body["use"] as? String,
              let string = body["url"] as? String,
              let url = URL(string: string) else { return }
        MainActor.assumeIsolated {
            guard let lease = webView?.lease, lease.resourceHost == use else { return }
            lease.onBlockedRemoteContent?(url)
        }
    }
}

// MARK: - Links

/// Lets a block load once, then sends every link click to the lease's
/// `openURL` instead of navigating the block. Embedded frames (a video
/// player) load normally. Each navigation runs the page's own scripts only if
/// the lease allows them.
final class NavigationPolicy: NSObject, WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let lease = (webView as? HTMLBlockWebView)?.lease
        preferences.allowsContentJavaScript = lease?.allowsJavaScript ?? false
        // A link with no target frame opens a new window: treat it as the main frame's.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame else {
            decisionHandler(.allow, preferences)
            return
        }
        let url = navigationAction.request.url
        guard navigationAction.navigationType == .linkActivated else {
            // Only the block's own page loads in the main frame; a redirect,
            // a meta refresh or a form never replaces it. An idle view only
            // ever loads a blank page.
            let page = Self.pageURL(for: lease?.baseURL, host: lease?.resourceHost ?? ResourceSchemeHandler.defaultHost)
            let isPageLoad = url.map { Self.isSamePage($0, as: page) } ?? false
            decisionHandler(isPageLoad ? .allow : .cancel, preferences)
            return
        }
        decisionHandler(.cancel, preferences)
        guard let url, let lease else { return }
        // A same-page anchor has nowhere to go in a block that fits its content.
        if url.fragment != nil, let current = webView.url, Self.isSamePage(url, as: current) { return }
        lease.openURL(ResourceSchemeHandler.fileURL(for: url) ?? url)
    }

    /// The URL a block's page loads at.
    static func pageURL(for baseURL: URL?, host: String = ResourceSchemeHandler.defaultHost) -> URL {
        ResourceSchemeHandler.pageBaseURL(for: baseURL, host: host) ?? URL(string: "about:blank")!
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

/// Serves a block's relative file references through the loader of the
/// requesting view's current lease. One handler serves every pooled view.
///
/// A block's page loads from `markdown-engine-resource://<host>/<folder>/`,
/// so a relative reference resolves the way it would against the folder
/// itself, `../` included; the handler turns the request back into a file URL.
/// The host names the use (see `HTMLBlockLease.resourceHost`), not a file.
final class ResourceSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    static let scheme = "markdown-engine-resource"
    static let defaultHost = "file"
    static let shared = ResourceSchemeHandler()

    /// Tasks WebKit hasn't stopped; a stopped task must not be answered.
    @MainActor private var activeTasks: Set<ObjectIdentifier> = []

    private override init() {}

    /// The URL a block's page loads from. A file base becomes a folder URL in
    /// this scheme; any other base is used as is.
    static func pageBaseURL(for baseURL: URL?, host: String = defaultHost) -> URL? {
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
        guard url.scheme == scheme, url.host?.isEmpty == false else { return nil }
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
        // Only the current use's own requests: a previous use's page, still
        // alive until the next one replaces it, asks under its own host.
        guard let requestURL = task.request.url, let file = Self.fileURL(for: requestURL),
              let lease = (webView as? HTMLBlockWebView)?.lease,
              requestURL.host == lease.resourceHost else {
            task.didFailWithError(URLError(.unsupportedURL))
            return
        }
        // The pending closure holds the task, so its identifier can't be
        // reused by another task until it is answered.
        let pending = PendingTask(task: task)
        activeTasks.insert(pending.id)
        let load = lease.resourceLoader
        let policy = lease.contentSecurityPolicy
        DispatchQueue.global(qos: .userInitiated).async {
            let data = load(file)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.answer(pending, url: requestURL, file: file, data: data, contentSecurityPolicy: policy)
                }
            }
        }
    }

    @MainActor
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(task))
    }

    @MainActor
    private func answer(_ pending: PendingTask, url: URL, file: URL, data: Data?, contentSecurityPolicy: String?) {
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
