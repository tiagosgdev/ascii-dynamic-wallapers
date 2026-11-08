import AVFoundation
import ScreenSaver

// Plays the recorded loop of whichever wallpaper the app last selected.
// The app writes that choice to scene.txt inside this bundle.
@objc(ASCIIWallpapersView)
final class ASCIIWallpapersView: ScreenSaverView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        startPlayback()

        // macOS keeps the saver process alive after dismissal and never calls
        // stopAnimation, so stop playing explicitly when the saver ends.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(saverWillStop),
            name: NSNotification.Name("com.apple.screensaver.willstop"), object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private func startPlayback() {
        let bundle = Bundle(for: ASCIIWallpapersView.self)
        let chosen = bundle.url(forResource: "scene", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "pond"
        guard let url = bundle.url(forResource: chosen, withExtension: "mp4")
                ?? bundle.url(forResource: "pond", withExtension: "mp4") else { return }

        player.isMuted = true
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))

        let video = AVPlayerLayer(player: player)
        video.videoGravity = .resizeAspectFill
        video.frame = bounds
        video.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(video)
        player.play()
    }

    @objc private func saverWillStop() {
        player.pause()
        if !isPreview { exit(0) }
    }

    override func animateOneFrame() {}
    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
