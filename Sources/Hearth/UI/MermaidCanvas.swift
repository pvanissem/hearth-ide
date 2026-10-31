import SwiftUI
import WebKit
import AppKit
import UniformTypeIdentifiers

/// Bridge from SwiftUI controls into the diagram's JavaScript (zoom, fit, export).
@MainActor
@Observable
final class MermaidController {
    weak var webView: WKWebView?
    var zoom: Double = 1
    var error: String?
    var rendered = false

    func zoomIn() { call("dk.zoomBy(1.25)") }
    func zoomOut() { call("dk.zoomBy(0.8)") }
    func fit() { call("dk.fit()") }
    func actualSize() { call("dk.reset()") }

    private func call(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func svg() async -> String? {
        guard let web = webView else { return nil }
        return try? await web.evaluateJavaScript("dk.svg()") as? String
    }

    func copySVG() async {
        guard let s = await svg() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func exportSVG(suggestedName: String) async {
        guard let s = await svg() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.svg]
        panel.nameFieldStringValue = suggestedName + ".svg"
        if panel.runModal() == .OK, let url = panel.url {
            try? s.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func exportPNG(suggestedName: String) async {
        guard let web = webView else { return }
        let config = WKSnapshotConfiguration()
        guard let image = try? await web.takeSnapshot(configuration: config),
              let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = suggestedName + ".png"
        if panel.runModal() == .OK, let url = panel.url { try? png.write(to: url) }
    }
}

/// Diagram canvas with pan & zoom plus floating controls.
/// Mouse: drag to pan, scroll to pan, pinch or ⌘/⌃-scroll to zoom at the cursor,
/// double-click to zoom in (⇧ double-click out). Keys: + − 0 (fit) 1 (100 %).
struct MermaidCanvas: View {
    let source: String
    let title: String
    var onOpenWindow: (() -> Void)? = nil
    var onError: ((String?) -> Void)? = nil
    private let controller = State(initialValue: MermaidController())
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = controller.wrappedValue
        ZStack(alignment: .bottomTrailing) {
            MermaidWebView(source: source, dark: colorScheme == .dark, controller: c)
                .onChange(of: c.error) { onError?(c.error) }
            if c.rendered {
                controls(c).padding(8)
            }
            if !c.rendered && c.error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let err = c.error {
                Label(err, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .lineLimit(3).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6)).padding(8)
            }
        }
    }

    private func controls(_ c: MermaidController) -> some View {
        HStack(spacing: 2) {
            Button { c.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }.help("Verkleinern (−)")
            Button { c.actualSize() } label: {
                Text("\(Int((c.zoom * 100).rounded())) %").font(.caption.monospacedDigit()).frame(minWidth: 42)
            }
            .help("Originalgröße (1)")
            Button { c.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }.help("Vergrößern (+)")
            Divider().frame(height: 16)
            Button { c.fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }
                .help("Einpassen (0)")
            Menu {
                Button("SVG kopieren") { Task { await c.copySVG() } }
                Button("Als SVG speichern …") { Task { await c.exportSVG(suggestedName: title) } }
                Button("Als PNG speichern …") { Task { await c.exportPNG(suggestedName: title) } }
            } label: { Image(systemName: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Exportieren")
            if let onOpenWindow {
                Button(action: onOpenWindow) { Image(systemName: "macwindow.on.rectangle") }.help("In eigenem Fenster öffnen")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .shadow(radius: 2, y: 1)
    }
}

/// Renders Mermaid offline with the bundled mermaid.min.js.
struct MermaidWebView: NSViewRepresentable {
    let source: String
    let dark: Bool
    let controller: MermaidController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.setURLSchemeHandler(MermaidResourceHandler(), forURLScheme: "hearth-mermaid")
        config.userContentController.add(context.coordinator, name: "mermaid")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        let coordinator = context.coordinator
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "hearth-mermaid-offline-v1",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]"#) { [weak view, weak coordinator] rules, error in
                guard let view, let coordinator else { return }
                guard let rules else {
                    coordinator.controller.error = "Offline-Schutz konnte nicht geladen werden: \(error?.localizedDescription ?? "unbekannt")"
                    return
                }
                config.userContentController.add(rules)
                coordinator.ready = true
                coordinator.loadOrRender(view)
            }
        // Zoom is handled in JS so it centers on the cursor and keeps text crisp.
        view.allowsMagnification = false
        view.setValue(false, forKey: "drawsBackground")
        controller.webView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(dark)#\(source.hashValue)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        context.coordinator.source = source
        context.coordinator.dark = dark
        controller.error = nil
        controller.rendered = false
        context.coordinator.loadOrRender(view)
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "mermaid")
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let controller: MermaidController
        var lastKey: String?
        var source = ""
        var dark = false
        var ready = false
        var loaded = false
        var page: URL?
        init(controller: MermaidController) { self.controller = controller }

        func loadOrRender(_ view: WKWebView) {
            guard ready else { return }
            if loaded {
                // Data crosses WebKit's argument bridge. Never interpolate repository text in HTML/JS.
                view.callAsyncJavaScript("await window.renderDiagram(source, dark)",
                                         arguments: ["source": source, "dark": dark], in: nil, in: .page) { [weak self] result in
                    if case .failure(let error) = result { self?.controller.error = error.localizedDescription }
                }
            } else if page == nil {
                guard MermaidAsset.url != nil else { controller.error = "mermaid.min.js nicht gefunden"; return }
                // No file:// grants or repository-readable temporary HTML files.
                page = MermaidResourceHandler.pageURL
                view.load(URLRequest(url: MermaidResourceHandler.pageURL))
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            loadOrRender(webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // No diagram links, popups, other file URLs or top-frame navigation.
            decisionHandler(navigationAction.request.url == page && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
        }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let zoom = body["zoom"] as? Double
            let ok = body["ok"] as? Bool
            let error = (body["error"] as? String)?.split(separator: "\n").prefix(2).joined(separator: " ")
            Task { @MainActor in
                if let zoom { self.controller.zoom = zoom }
                if let ok {
                    self.controller.rendered = ok
                    self.controller.error = ok ? nil : error
                }
            }
        }
    }
}

/// A closed, in-memory origin: WebKit can request exactly the fixed page and the
/// bundled JS. No URL-to-filesystem mapping, directory grant, or network fallback.
final class MermaidResourceHandler: NSObject, WKURLSchemeHandler {
    static let pageURL = URL(string: "hearth-mermaid://renderer/index.html")!

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "hearth-mermaid", url.host == "renderer",
              url.query == nil, url.fragment == nil else {
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        let data: Data
        let mime: String
        if url.path == "/index.html" {
            data = Data(MermaidPage.html().utf8)
            mime = "text/html"
        } else if url.path == "/" + MermaidAsset.fileName, let asset = MermaidAsset.url,
                  let bytes = try? Data(contentsOf: asset) {
            data = bytes
            mime = "application/javascript"
        } else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

enum MermaidPage {
    static func html() -> String {
        let nonce = UUID().uuidString
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; img-src data:; connect-src 'none'; font-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
          html,body{margin:0;height:100%;overflow:hidden;background:transparent;font-family:-apple-system;
            -webkit-user-select:none;cursor:grab}
          body.dragging{cursor:grabbing}
          #c{position:absolute;left:0;top:0;transform-origin:0 0;will-change:transform}
          #c svg{display:block;max-width:none!important}
        </style>
        <script nonce="\(nonce)" src="\(MermaidAsset.fileName)"></script></head>
        <body><div id="c"></div><script nonce="\(nonce)">
        const post = m => window.webkit.messageHandlers.mermaid.postMessage(m);
        const c = document.getElementById("c");
        const dk = {
          s:1, x:0, y:0, w:0, h:0,
          apply(){ c.style.transform = `translate(${this.x}px,${this.y}px) scale(${this.s})`; post({zoom:this.s}); },
          zoomAt(f, cx, cy){
            const ns = Math.min(10, Math.max(0.05, this.s * f));
            this.x = cx - (cx - this.x) * ns / this.s;
            this.y = cy - (cy - this.y) * ns / this.s;
            this.s = ns; this.apply();
          },
          zoomBy(f){ this.zoomAt(f, innerWidth/2, innerHeight/2); },
          fit(){
            if(!this.w) return;
            const pad = 24;
            this.s = Math.min(4, Math.min((innerWidth-pad*2)/this.w, (innerHeight-pad*2)/this.h));
            this.x = (innerWidth - this.w*this.s)/2; this.y = (innerHeight - this.h*this.s)/2; this.apply();
          },
          reset(){
            this.s = 1;
            this.x = Math.max(12, (innerWidth - this.w)/2); this.y = Math.max(12, (innerHeight - this.h)/2);
            this.apply();
          },
          svg(){ const s = c.querySelector("svg"); return s ? s.outerHTML : null; }
        };
        let renderGeneration = 0;
        window.renderDiagram = async (source, dark) => {
          const generation = ++renderGeneration;
          try {
          mermaid.initialize({startOnLoad:false, theme:dark ? "dark" : "default", securityLevel:"strict",
            secure:["securityLevel","startOnLoad","maxTextSize","suppressErrorRendering"], suppressErrorRendering:true});
          const r = await mermaid.render("g" + generation, source);
          if (generation !== renderGeneration) return;
          c.innerHTML = r.svg;
          const svg = c.querySelector("svg");
          const vb = svg.viewBox && svg.viewBox.baseVal;
          dk.w = vb && vb.width ? vb.width : svg.getBoundingClientRect().width;
          dk.h = vb && vb.height ? vb.height : svg.getBoundingClientRect().height;
          svg.setAttribute("width", dk.w); svg.setAttribute("height", dk.h); svg.style.maxWidth = "none";
          dk.fit();
          post({ok:true});
          } catch(e) { if (generation === renderGeneration) post({ok:false, error:String(e && e.message || e)}); }
        };

        // Pinch arrives as ctrl+wheel in WebKit; ⌘+wheel zooms too, plain wheel pans.
        addEventListener("wheel", e => {
          e.preventDefault();
          if (e.ctrlKey || e.metaKey) dk.zoomAt(Math.exp(-e.deltaY * 0.01), e.clientX, e.clientY);
          else { dk.x -= e.deltaX; dk.y -= e.deltaY; dk.apply(); }
        }, {passive:false});
        let drag = null;
        addEventListener("mousedown", e => { drag = {x:e.clientX - dk.x, y:e.clientY - dk.y}; document.body.classList.add("dragging"); });
        addEventListener("mousemove", e => { if (drag) { dk.x = e.clientX - drag.x; dk.y = e.clientY - drag.y; dk.apply(); } });
        addEventListener("mouseup", () => { drag = null; document.body.classList.remove("dragging"); });
        addEventListener("dblclick", e => dk.zoomAt(e.shiftKey ? 0.5 : 2, e.clientX, e.clientY));
        addEventListener("keydown", e => {
          if (e.key === "+" || e.key === "=") dk.zoomBy(1.25);
          else if (e.key === "-") dk.zoomBy(0.8);
          else if (e.key === "0") dk.fit();
          else if (e.key === "1") dk.reset();
          else if (e.key.startsWith("Arrow")) {
            const d = e.shiftKey ? 120 : 40;
            if (e.key === "ArrowLeft") dk.x += d; if (e.key === "ArrowRight") dk.x -= d;
            if (e.key === "ArrowUp") dk.y += d; if (e.key === "ArrowDown") dk.y -= d;
            dk.apply();
          } else return;
          e.preventDefault();
        });
        </script></body></html>
        """
    }
}
