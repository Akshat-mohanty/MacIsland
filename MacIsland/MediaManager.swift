import Foundation
import AppKit
import Combine
import SwiftUI

enum MediaService: String, Sendable {
    case spotify
    case youtube
    case appleMusic
    case other
}

final class MediaManager: ObservableObject {
    @Published var title: String = "Not Playing"
    @Published var artist: String = ""
    @Published var artworkImage: NSImage? = nil
    @Published var isPlaying: Bool = false
    @Published var isYouTube: Bool = false
    @Published var mediaService: MediaService = .other
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isScrubbing: Bool = false
    @Published var currentSource: String = ""
    
    var accentColor: Color {
        switch mediaService {
        case .spotify:
            return Color(red: 0.22, green: 0.86, blue: 0.45) // Spotify Green
        case .youtube:
            return Color(red: 240/255.0, green: 179/255.0, blue: 36/255.0) // YouTube #f0b324
        case .appleMusic:
            return Color(red: 250/255.0, green: 45/255.0, blue: 72/255.0) // Apple Music Red
        case .other:
            return Color(red: 0.22, green: 0.86, blue: 0.45)
        }
    }
    
    private var timer: Timer?
    private var lastArtworkURL: String = ""
    private var seekLockUntil: Date = .distantPast
    
    init() {
        startPolling()
    }
    
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.fetchNowPlayingInfo()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.fetchNowPlayingInfo()
        }
    }
    
    func fetchNowPlayingInfo() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        let hasSpotify = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.spotify.client" || name.localizedCaseInsensitiveContains("Spotify")
        }
        let hasMusic = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.apple.Music" || name == "Music"
        }
        let hasBrave = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.brave.Browser" || id.hasPrefix("com.brave.Browser.app") || name == "Brave Browser" || name == "YouTube" || name.localizedCaseInsensitiveContains("Brave") || name.localizedCaseInsensitiveContains("YouTube")
        }
        let hasChrome = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.google.Chrome" || id.hasPrefix("com.google.Chrome.app") || name == "Google Chrome" || name.localizedCaseInsensitiveContains("Chrome")
        }
        let hasArc = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "company.thebrowser.Browser" || name == "Arc"
        }
        let hasSafari = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.apple.Safari" || name == "Safari"
        }
        let hasEdge = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.microsoft.edgemac" || id.hasPrefix("com.microsoft.edgemac.app") || name == "Microsoft Edge" || name.localizedCaseInsensitiveContains("Edge")
        }

        let rawScraper = """
        (function() {
            var videos = Array.from(document.querySelectorAll('video'));
            var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
            var a = document.querySelector('audio');
            var media = v || a;
            var url = window.location.href;
            var track = '', artist = '', isPlaying = 'paused', imgUrl = '', curPos = 0, curDur = 0;

            var ytPlayer = document.querySelector('.html5-video-player');
            var ytPlaying = ytPlayer ? ytPlayer.classList.contains('playing-mode') : (v && !v.paused);

            if (url.includes('music.youtube.com')) {
                var titleEl = document.querySelector('.title.ytmusic-player-bar');
                track = titleEl ? titleEl.textContent.trim() : document.title.replace(/ - YouTube Music$/, '');
                var artEl = document.querySelector('.ytmusic-player-bar .byline a, .ytmusic-player-bar .byline, .ytmusic-player-bar .subtitle');
                artist = artEl ? artEl.textContent.trim() : 'YouTube Music';
                var imgEl = document.querySelector('.ytmusic-player-bar .image, .ytmusic-player-bar img');
                if (imgEl && imgEl.src) imgUrl = imgEl.src;
                isPlaying = ytPlaying ? 'playing' : 'paused';
            } else if (url.includes('youtube.com') || url.includes('youtu.be')) {
                var titleEl = document.querySelector('h1.ytd-watch-metadata yt-formatted-string, #title h1 yt-formatted-string, ytd-watch-flexy h1, .ytp-title-link, .title.ytd-video-primary-info-renderer');
                track = titleEl ? (titleEl.textContent || titleEl.innerText).trim() : document.title.replace(/ - YouTube$/, '');
                var artEl = document.querySelector('#owner ytd-channel-name yt-formatted-string, #upload-info ytd-channel-name yt-formatted-string, ytd-channel-name a, #channel-name a');
                artist = artEl ? (artEl.textContent || artEl.innerText).trim() : 'YouTube';
                isPlaying = ytPlaying ? 'playing' : 'paused';
            } else if (url.includes('spotify.com')) {
                var t = document.querySelector('[data-testid="context-item-link"]');
                var art = document.querySelector('[data-testid="context-item-info-subtitles"]');
                var pb = document.querySelector('[data-testid="control-button-playpause"]');
                var img = document.querySelector('img[data-testid="cover-art-image"]') || document.querySelector('img[data-testid="context-item-image"]');
                if (t && art) {
                    track = t.innerText;
                    artist = art.innerText.replace(/[\\r\\n]+/g, ', ');
                    isPlaying = (pb && pb.getAttribute('aria-label') === 'Pause') ? 'playing' : 'paused';
                    imgUrl = img ? img.src : '';
                }
                var inp = document.querySelector('[data-testid="playback-progressbar"] input');
                if (inp) {
                    curPos = Math.round(Number(inp.value) / 1000);
                    curDur = Math.round(Number(inp.max) / 1000);
                } else {
                    var curTimeEl = document.querySelector('[data-testid="playback-position"]');
                    var durTimeEl = document.querySelector('[data-testid="playback-duration"]');
                    if (curTimeEl && durTimeEl) {
                        var p1 = curTimeEl.innerText.trim().split(':').map(Number);
                        var p2 = durTimeEl.innerText.trim().split(':').map(Number);
                        if (p1.length === 2) curPos = p1[0] * 60 + p1[1];
                        if (p2.length === 2) curDur = p2[0] * 60 + p2[1];
                    }
                }
            }

            if (media && !url.includes('spotify.com')) {
                curPos = media.currentTime || 0;
                curDur = (isFinite(media.duration) && media.duration) ? media.duration : 0;
            }

            if (!imgUrl && (url.includes('youtube.com') || url.includes('youtu.be'))) {
                var videoId = '';
                try {
                    var p = new URLSearchParams(window.location.search);
                    if (p.has('v')) videoId = p.get('v');
                } catch(e) {}
                if (!videoId && url.includes('/shorts/')) {
                    var parts = url.split('/shorts/');
                    if (parts.length > 1) videoId = parts[1].split('?')[0].split('/')[0];
                }
                if (videoId) {
                    imgUrl = 'https://i.ytimg.com/vi/' + videoId + '/hqdefault.jpg';
                } else {
                    var metaImg = document.querySelector('link[rel="image_src"], meta[property="og:image"]');
                    imgUrl = metaImg ? (metaImg.href || metaImg.content) : '';
                }
            }

            var service = "other";
            if (url.includes('youtube.com') || url.includes('youtu.be') || url.includes('music.youtube.com')) {
                service = 'youtube';
            } else if (url.includes('spotify.com')) {
                service = 'spotify';
            }

            if (track) {
                return track.trim() + '|' + artist.trim() + '|' + isPlaying + '|' + (imgUrl || 'none') + '|' + Math.round(curPos) + '|' + Math.round(curDur) + '|' + service;
            }
            return 'null';
        })();
        """

        let escapedScraper = rawScraper
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        var scriptSource = "set webScraper to \"" + escapedScraper + "\"\n\n"

        // 1. Actively playing native apps
        if hasSpotify {
            scriptSource += """
            try
                tell application "Spotify"
                    if player state is playing then
                        set trackName to (name of current track)
                        set trackArtist to (artist of current track)
                        set curPos to (player position)
                        set curDur to (duration of current track) / 1000
                        return "SpotifyNative|" & trackName & "|" & trackArtist & "|playing|none|" & curPos & "|" & curDur & "|spotify"
                    end if
                end tell
            end try
            
            """
        }

        if hasMusic {
            scriptSource += """
            try
                tell application "Music"
                    if player state is playing then
                        set trackName to (name of current track)
                        set trackArtist to (artist of current track)
                        set curPos to (player position)
                        set curDur to (duration of current track)
                        return "MusicNative|" & trackName & "|" & trackArtist & "|playing|none|" & curPos & "|" & curDur & "|applemusic"
                    end if
                end tell
            end try
            
            """
        }

        // 2. Actively playing browser tabs
        let chromiumBrowsers = [
            ("Brave Browser", hasBrave, "Brave"),
            ("Google Chrome", hasChrome, "Chrome"),
            ("Arc", hasArc, "Arc"),
            ("Microsoft Edge", hasEdge, "Edge")
        ]

        for (appName, isRunning, tag) in chromiumBrowsers where isRunning {
            scriptSource += """
            try
                tell application "\(appName)"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" and res contains "|playing|" then
                                    return "\(tag)|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end try
            
            """
        }

        if hasSafari {
            scriptSource += """
            try
                tell application "Safari"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to do JavaScript webScraper in t
                                if res is not missing value and res is not "null" and res contains "|playing|" then
                                    return "Safari|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end try
            
            """
        }

        // 3. Paused native apps
        if hasSpotify {
            scriptSource += """
            try
                tell application "Spotify"
                    set trackName to (name of current track)
                    set trackArtist to (artist of current track)
                    set curPos to (player position)
                    set curDur to (duration of current track) / 1000
                    return "SpotifyNative|" & trackName & "|" & trackArtist & "|paused|none|" & curPos & "|" & curDur & "|spotify"
                end tell
            end try
            
            """
        }

        if hasMusic {
            scriptSource += """
            try
                tell application "Music"
                    set trackName to (name of current track)
                    set trackArtist to (artist of current track)
                    set curPos to (player position)
                    set curDur to (duration of current track)
                    return "MusicNative|" & trackName & "|" & trackArtist & "|paused|none|" & curPos & "|" & curDur & "|applemusic"
                end tell
            end try
            
            """
        }

        // 4. Paused browser tabs
        for (appName, isRunning, tag) in chromiumBrowsers where isRunning {
            scriptSource += """
            try
                tell application "\(appName)"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" then
                                    return "\(tag)|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end try
            
            """
        }

        if hasSafari {
            scriptSource += """
            try
                tell application "Safari"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to do JavaScript webScraper in t
                                if res is not missing value and res is not "null" then
                                    return "Safari|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end try
            
            """
        }

        scriptSource += "\nreturn \"\"\n"
        
        executeScriptAndParse(scriptSource)
    }
    
    private static let artworkCache = NSCache<NSString, NSImage>()
    private var consecutiveNotPlayingCount = 0
    
    private func executeScriptAndParse(_ scriptSource: String) {
        guard let script = NSAppleScript(source: scriptSource) else {
            setNotPlaying()
            return
        }
        
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        
        if let resultString = result.stringValue, !resultString.isEmpty {
            let parts = resultString.components(separatedBy: "|")
            if parts.count >= 5 {
                let sourceApp = parts[0]
                let newTitle = parts[1].isEmpty ? "Unknown" : parts[1]
                let newArtist = parts[2]
                let newIsPlaying = (parts[3] == "playing")
                let imgUrlString = parts[4]
                let newCurPos = parts.count >= 6 ? (Double(parts[5]) ?? 0) : 0
                let newDuration = parts.count >= 7 ? (Double(parts[6]) ?? 0) : 0
                
                let newIsYouTube = imgUrlString.contains("youtube.com") || imgUrlString.contains("ytimg.com") || imgUrlString.contains("youtu.be") || sourceApp.contains("YouTube")
                
                let serviceTag = parts.count >= 8 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
                let newService: MediaService
                if serviceTag == "spotify" || sourceApp == "SpotifyNative" || imgUrlString.contains("spotify.com") {
                    newService = .spotify
                } else if serviceTag == "youtube" || newIsYouTube {
                    newService = .youtube
                } else if serviceTag == "applemusic" || sourceApp == "MusicNative" {
                    newService = .appleMusic
                } else {
                    newService = .other
                }
                
                Task { @MainActor in
                    self.consecutiveNotPlayingCount = 0
                    self.currentSource = sourceApp
                    self.title = newTitle
                    self.artist = newArtist
                    self.isPlaying = newIsPlaying
                    self.isYouTube = newIsYouTube
                    self.mediaService = newService
                    if !self.isScrubbing && Date() >= self.seekLockUntil {
                        self.currentTime = newCurPos
                    }
                    self.duration = newDuration
                    
                    if imgUrlString != "none" && !imgUrlString.isEmpty {
                        if let cached = Self.artworkCache.object(forKey: imgUrlString as NSString) {
                            self.artworkImage = cached
                        } else if self.lastArtworkURL != imgUrlString, let url = URL(string: imgUrlString) {
                            self.lastArtworkURL = imgUrlString
                            Task.detached(priority: .userInitiated) {
                                if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
                                    await MainActor.run {
                                        Self.artworkCache.setObject(img, forKey: imgUrlString as NSString)
                                        if self.lastArtworkURL == imgUrlString {
                                            self.artworkImage = img
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        self.lastArtworkURL = ""
                        self.loadAppIcon(for: sourceApp)
                    }
                }
            } else {
                setNotPlaying()
            }
        } else {
            setNotPlaying()
        }
    }
    
    private func loadAppIcon(for sourceApp: String) {
        let bundleId: String
        if sourceApp == "SpotifyNative" { bundleId = "com.spotify.client" }
        else if sourceApp == "MusicNative" { bundleId = "com.apple.Music" }
        else if sourceApp == "Brave" { bundleId = "com.brave.Browser" }
        else if sourceApp == "Chrome" { bundleId = "com.google.Chrome" }
        else if sourceApp == "Arc" { bundleId = "company.thebrowser.Browser" }
        else { bundleId = "com.apple.Safari" }
        
        if let cached = Self.artworkCache.object(forKey: bundleId as NSString) {
            self.artworkImage = cached
        } else if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let img = NSWorkspace.shared.icon(forFile: appUrl.path)
            Self.artworkCache.setObject(img, forKey: bundleId as NSString)
            self.artworkImage = img
        }
    }
    
    private func setNotPlaying() {
        Task { @MainActor in
            self.consecutiveNotPlayingCount += 1
            if self.consecutiveNotPlayingCount >= 3 {
                self.lastArtworkURL = ""
                self.currentSource = ""
                self.title = "Not Playing"
                self.artist = ""
                self.isPlaying = false
                self.artworkImage = nil
                self.isYouTube = false
                self.mediaService = .other
                self.currentTime = 0
                self.duration = 0
            }
        }
    }
    
    func togglePlayPause() {
        runControlCommand("playpause")
    }
    
    func skipForward() {
        runControlCommand("next track")
    }
    
    func skipBackward() {
        runControlCommand("previous track")
    }
    
    func seek(to seconds: Double) {
        self.currentTime = seconds
        self.seekLockUntil = Date().addingTimeInterval(1.2)
        let source = self.currentSource
        let runningApps = NSWorkspace.shared.runningApplications
        let hasBrave = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.brave.Browser" || id.hasPrefix("com.brave.Browser.app") || name == "Brave Browser" || name == "YouTube" || name.localizedCaseInsensitiveContains("Brave") || name.localizedCaseInsensitiveContains("YouTube")
        }
        let hasChrome = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.google.Chrome" }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "") == "company.thebrowser.Browser" }
        let hasSafari = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Safari" }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var scriptSource = ""

            if source == "SpotifyNative" {
                scriptSource = """
                try
                    tell application "Spotify"
                        set player position to \(seconds)
                    end tell
                end try
                """
            } else if source == "MusicNative" {
                scriptSource = """
                try
                    tell application "Music"
                        set player position to \(seconds)
                    end tell
                end try
                """
            } else {
                let jsSeek = """
                (function() {
                    var targetSec = \(seconds);
                    var inp = document.querySelector('[data-testid="playback-progressbar"] input');
                    if (inp) {
                        var targetMs = targetSec * 1000;
                        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
                        nativeSetter.call(inp, targetMs);
                        inp.dispatchEvent(new Event('input', { bubbles: true }));
                        inp.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                    var v = Array.from(document.querySelectorAll('video, audio')).find(function(x){return !x.paused;}) || document.querySelector('.html5-main-video') || document.querySelector('video, audio');
                    if (v) {
                        try { v.currentTime = targetSec; } catch(e) {}
                    }
                })();
                """
                
                let escapedJsSeek = jsSeek
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                
                let browsers = [
                    ("Brave Browser", hasBrave),
                    ("Google Chrome", hasChrome),
                    ("Arc", hasArc)
                ]
                
                for (b, isRunning) in browsers where isRunning {
                    scriptSource += """
                    try
                        tell application "\(b)"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                        execute t javascript "\(escapedJsSeek)"
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    
                    """
                }
                
                if hasSafari {
                    scriptSource += """
                    try
                        tell application "Safari"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                        do JavaScript "\(escapedJsSeek)" in t
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    
                    """
                }
            }

            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(nil)
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                self?.fetchNowPlayingInfo()
            }
        }
    }
    
    static func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite && seconds > 0 else { return "0:00" }
        let totalSec = Int(seconds)
        let hours = totalSec / 3600
        let mins = (totalSec % 3600) / 60
        let secs = totalSec % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        } else {
            return String(format: "%d:%02d", mins, secs)
        }
    }
    
    private func runControlCommand(_ command: String) {
        let source = self.currentSource
        let runningApps = NSWorkspace.shared.runningApplications
        let hasBrave = runningApps.contains { app in
            let id = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return id == "com.brave.Browser" || id.hasPrefix("com.brave.Browser.app") || name == "Brave Browser" || name == "YouTube" || name.localizedCaseInsensitiveContains("Brave") || name.localizedCaseInsensitiveContains("YouTube")
        }
        let hasChrome = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.google.Chrome" }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "") == "company.thebrowser.Browser" }
        let hasSafari = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Safari" }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var scriptSource = ""

            if source == "SpotifyNative" {
                scriptSource = """
                try
                    tell application "Spotify" to \(command)
                end try
                """
            } else if source == "MusicNative" {
                scriptSource = """
                try
                    tell application "Music" to \(command)
                end try
                """
            } else {
                let jsCmd = """
                (function() {
                    var cmd = '\(command)';
                    if (cmd === 'playpause') {
                        var ytPlayBtn = document.querySelector('.ytp-play-button, .play-pause-button.ytmusic-player-bar, #play-pause-button, [data-testid=\"control-button-playpause\"]');
                        if (ytPlayBtn) {
                            ytPlayBtn.click();
                        } else {
                            var videos = Array.from(document.querySelectorAll('video'));
                            var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                            if (v) {
                                if (v.paused) v.play(); else v.pause();
                            }
                        }
                    } else if (cmd === 'next track') {
                        var nextBtn = document.querySelector('.ytp-next-button, .next-button.ytmusic-player-bar, [data-testid=\"control-button-skip-forward\"]');
                        var videos = Array.from(document.querySelectorAll('video'));
                        var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                        if (v && isFinite(v.duration)) {
                            v.currentTime = Math.min(v.duration, v.currentTime + 10);
                        } else if (nextBtn) {
                            nextBtn.click();
                        }
                    } else if (cmd === 'previous track') {
                        var videos = Array.from(document.querySelectorAll('video'));
                        var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                        if (v) {
                            if (v.currentTime > 3) {
                                v.currentTime = 0;
                            } else {
                                v.currentTime = Math.max(0, v.currentTime - 10);
                            }
                        } else {
                            var prevBtn = document.querySelector('.ytp-prev-button, .previous-button.ytmusic-player-bar, [data-testid=\"control-button-skip-back\"]');
                            if (prevBtn) prevBtn.click();
                        }
                    }
                })();
                """
                
                let escapedJsCmd = jsCmd
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                
                let browsers = [
                    ("Brave Browser", hasBrave),
                    ("Google Chrome", hasChrome),
                    ("Arc", hasArc)
                ]
                
                for (b, isRunning) in browsers where isRunning {
                    scriptSource += """
                    try
                        tell application "\(b)"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                        execute t javascript "\(escapedJsCmd)"
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    
                    """
                }
                
                if hasSafari {
                    scriptSource += """
                    try
                        tell application "Safari"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                        do JavaScript "\(escapedJsCmd)" in t
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    
                    """
                }
            }

            if let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(nil)
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                self?.fetchNowPlayingInfo()
            }
        }
    }
}