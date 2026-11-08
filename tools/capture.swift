// Records a scene's base animation by rendering fixed frames in WebKit and
// writing PNGs to stdout, for piping into ffmpeg.
// usage: capture <page url> <frames> <setup js> <per-frame js using $T>
import Cocoa
import WebKit

let args = CommandLine.arguments
guard args.count == 5, URL(string: args[1]) != nil, Int(args[2]) != nil else {
    fputs("usage: capture <page url> <frames> <setup js> <frame js>\n", stderr)
    exit(64)
}
let page = URL(string: args[1])!
let frames = Int(args[2])!
let setupJS = args[3], frameJS = args[4]

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1512, height: 982),
                      styleMask: .borderless, backing: .buffered, defer: false)
let web = WKWebView(frame: window.contentView!.bounds, configuration: WKWebViewConfiguration())
window.contentView = web
window.orderFront(nil)

final class Recorder: NSObject, WKNavigationDelegate {
    var index = 0
    func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            v.evaluateJavaScript(setupJS + ";1") { _, e in
                if let e { fputs("setup failed: \(e)\n", stderr); exit(1) }
                self.next(v)
            }
        }
    }
    func next(_ v: WKWebView) {
        guard index < frames else { exit(0) }
        let t = Double(index) / 30
        v.evaluateJavaScript(frameJS.replacingOccurrences(of: "$T", with: String(t))) { r, e in
            guard let s = r as? String, let comma = s.firstIndex(of: ","),
                  let png = Data(base64Encoded: String(s[s.index(after: comma)...])) else {
                fputs("frame \(self.index) failed: \(e.map(String.init(describing:)) ?? "nil")\n", stderr)
                exit(1)
            }
            FileHandle.standardOutput.write(png)
            self.index += 1
            if self.index % 150 == 0 { fputs("frame \(self.index)/\(frames)\n", stderr) }
            self.next(v)
        }
    }
}

let recorder = Recorder()
web.navigationDelegate = recorder
web.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
app.run()
