// Renders icon.svg to icon-1024.png with WebKit. Usage: swift render.swift <svg> <png>
import Cocoa
import WebKit

let args = CommandLine.arguments
let svgURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let cfg = WKWebViewConfiguration()
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024), configuration: cfg)
web.setValue(false, forKey: "drawsBackground")
let win = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.contentView = web
if #available(macOS 12.0, *) { web.underPageBackgroundColor = .clear }

final class Nav: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let c = WKSnapshotConfiguration()
            c.rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
            c.snapshotWidth = 1024
            webView.takeSnapshot(with: c) { img, err in
                guard let img, let tiff = img.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    print("snapshot failed: \(String(describing: err))"); exit(1)
                }
                try! png.write(to: outURL)
                print("wrote \(outURL.path)")
                exit(0)
            }
        }
    }
}
let nav = Nav()
web.navigationDelegate = nav
let svg = try! String(contentsOf: svgURL)
let html = "<html><body style='margin:0;background:transparent'>\(svg)</body></html>"
web.loadHTMLString(html, baseURL: svgURL.deletingLastPathComponent())
app.run()
