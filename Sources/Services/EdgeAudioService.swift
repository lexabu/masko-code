import AVFoundation
import Foundation

/// Plays one-shot or looping audio for edge transitions.
/// Downloads remote audio files to a local cache before playback.
@MainActor
final class EdgeAudioService {

    static let shared = EdgeAudioService()

    private var player: AVAudioPlayer?
    private var isLooping = false
    private var downloadCache: [String: URL] = [:]
    private var pendingDownloads: Set<String> = []

    private init() {}

    /// Play a sound for an edge. Downloads if needed, then plays.
    func play(_ sound: EdgeSound) {
        let shouldLoop = sound.loop ?? false
        let volume = Float(sound.volume ?? 1.0)

        // Try to play from cache synchronously first
        if let localURL = downloadCache[sound.url] {
            playLocal(localURL, loop: shouldLoop, volume: volume, label: sound.url)
            return
        }

        // Download async then play
        Task {
            guard let localURL = await resolveAudio(sound.url) else {
                print("[masko-desktop] Audio: failed to resolve \(sound.url)")
                return
            }
            playLocal(localURL, loop: shouldLoop, volume: volume, label: sound.url)
        }
    }

    private func playLocal(_ url: URL, loop: Bool, volume: Float, label: String) {
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = volume
            newPlayer.numberOfLoops = loop ? -1 : 0
            newPlayer.prepareToPlay()

            player?.stop()
            player = newPlayer
            isLooping = loop
            let playing = newPlayer.play()

            let mode = loop ? "looping" : "one-shot"
            if !playing { print("[masko-desktop] Audio: play failed for \(url.lastPathComponent)") }
        } catch {
            print("[masko-desktop] Audio: playback error - \(error.localizedDescription)")
        }
    }

    /// Stop looping audio only (one-shot sounds keep playing)
    func stopLooping() {
        if isLooping {
            player?.stop()
            player = nil
            isLooping = false
        }
    }

    /// Stop all audio
    func stop() {
        player?.stop()
        player = nil
        isLooping = false
    }

    /// Preload audio files from a config so they're cached when needed
    func preload(_ config: MaskoAnimationConfig) {
        let urls = config.edges.compactMap { $0.sound?.url }
        let unique = Set(urls)
        print("[masko-desktop] Audio: preloading \(unique.count) sound(s) from \(config.edges.count) edges")
        guard !unique.isEmpty else {
            print("[masko-desktop] Audio: no sounds to preload")
            return
        }
        Task {
            for urlString in unique {
                let result = await resolveAudio(urlString)
                if result == nil { print("[masko-desktop] Audio: failed to preload \(urlString)") }
            }
        }
    }

    // MARK: - Private

    /// Resolve a URL string to a local file URL, downloading if remote.
    private func resolveAudio(_ urlString: String) async -> URL? {
        // Already cached
        if let cached = downloadCache[urlString] {
            return cached
        }

        guard let url = URL(string: urlString) else { return nil }

        // Local file
        if url.isFileURL {
            downloadCache[urlString] = url
            return url
        }

        // Prevent duplicate downloads
        guard !pendingDownloads.contains(urlString) else { return nil }
        pendingDownloads.insert(urlString)
        defer { pendingDownloads.remove(urlString) }

        // Download to temp cache
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("masko-audio")
            try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

            let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
            let filename = url.lastPathComponent.isEmpty ? "\(urlString.hashValue).\(ext)" : url.lastPathComponent
            let localURL = cacheDir.appendingPathComponent(filename)

            try data.write(to: localURL)
            downloadCache[urlString] = localURL
            print("[masko-desktop] Audio: cached \(filename)")
            return localURL
        } catch {
            print("[masko-desktop] Audio: download failed — \(error.localizedDescription)")
            return nil
        }
    }
}
