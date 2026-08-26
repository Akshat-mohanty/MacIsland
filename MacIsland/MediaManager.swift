import Foundation
import AppKit
import Combine
import SwiftUI

enum MediaService: String, Sendable {
    case spotify
    case youtube
    case appleMusic
    case netflix
    case other
}

final class MediaManager: ObservableObject {
    @Published var title: String = "Not Playing"
    @Published var artist: String = ""
    @Published var artworkImage: NSImage? = nil
    @Published var isPlaying: Bool = false
    @Published var isYouTube: Bool = false
    @Published var isNetflix: Bool = false
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
        case .appleMusic, .netflix:
            return Color(red: 250/255.0, green: 45/255.0, blue: 72/255.0) // Apple Music / Netflix Red
        case .other:
            return Color(red: 0.22, green: 0.86, blue: 0.45)
        }
    }
    
    private var timer: Timer?
    private var progressTimer: Timer?
    private var lastArtworkURL: String = ""
    private var seekLockUntil: Date = .distantPast
    
    private typealias MRGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private static let mrGetNowPlayingInfo: MRGetNowPlayingInfoFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(sym, to: MRGetNowPlayingInfoFunc.self)
    }()
    
    init() {
        startPolling()
    }
    
    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.fetchNowPlayingInfo()
            }
        }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isPlaying && !self.isScrubbing && self.duration > 0 && Date() >= self.seekLockUntil {
                    let nextTime = self.currentTime + 0.1
                    if nextTime <= self.duration {
                        self.currentTime = nextTime
                    }
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            self.fetchNowPlayingInfo()
        }
    }
    
    private func runIsolatedAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let str = result.stringValue, !str.isEmpty, str != "null" {
            return str
        }
        return nil
    }

    func fetchNowPlayingInfo() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Strict bundle identifier matching to NEVER launch an unopen or uninstalled app
        let hasSpotify = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.spotify.client" }
        let hasMusic = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        let hasBrave = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.brave.Browser" }
        let hasChrome = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.google.Chrome" }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "") == "company.thebrowser.Browser" }
        let hasSafari = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Safari" }
        let hasEdge = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.microsoft.edgemac" }

        let rawScraper = """
        (function() {
            var videos = Array.from(document.querySelectorAll('video'));
            var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
            var a = document.querySelector('audio');
            var media = v || a;
            var url = window.location.href;
            var track = '', artist = '', isPlaying = 'paused', imgUrl = '', curPos = 0, curDur = 0;

            var ytPlayer = document.querySelector('.html5-video-player');
            var ytPlaying = (ytPlayer && ytPlayer.classList.contains('playing-mode')) || (v && !v.paused && !v.ended && v.currentTime > 0);
            if (v && v.paused && (!ytPlayer || !ytPlayer.classList.contains('playing-mode'))) {
                ytPlaying = false;
            }

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
            } else if (url.includes('netflix.com')) {
                var titleEl = document.querySelector('[data-uia="video-title"], .video-title, [data-uia="watch-video-title"], .ellipsize-js');
                var showName = '';
                var episodeName = '';
                if (titleEl) {
                    var h4 = titleEl.querySelector('h4');
                    var spans = Array.from(titleEl.querySelectorAll('span'))
                        .map(function(s) { return (s.textContent || s.innerText || '').trim(); })
                        .filter(Boolean);
                    if (h4) {
                        showName = (h4.textContent || h4.innerText || '').trim();
                        if (spans.length > 0) {
                            episodeName = spans.join(' - ');
                        }
                    } else if (spans.length > 0) {
                        showName = spans[0];
                        if (spans.length > 1) {
                            episodeName = spans.slice(1).join(' - ');
                        }
                    } else {
                        showName = (titleEl.textContent || titleEl.innerText || '').trim();
                    }
                }

                if (!showName) {
                    var ogTitle = document.querySelector('meta[property="og:title"]');
                    if (ogTitle && ogTitle.content) {
                        showName = ogTitle.content.trim();
                    }
                }

                if (!showName && document.title) {
                    showName = document.title.trim();
                }

                showName = showName
                    .replace(/^Watch\\s+/i, '')
                    .replace(/\\s*[\\|\\-–—]\\s*Netflix.*$/i, '')
                    .replace(/^Netflix\\s*[\\|\\-–—]\\s*/i, '')
                    .trim();

                if (episodeName) {
                    episodeName = episodeName
                        .replace(/^Watch\\s+/i, '')
                        .replace(/\\s*[\\|\\-–—]\\s*Netflix.*$/i, '')
                        .replace(/^Netflix\\s*[\\|\\-–—]\\s*/i, '')
                        .trim();
                }

                if (showName && showName.toLowerCase() !== 'netflix' && !showName.toLowerCase().includes('watch tv shows online')) {
                    track = showName;
                    artist = episodeName || 'Netflix';
                } else if (episodeName) {
                    track = episodeName;
                    artist = 'Netflix';
                } else if (url.includes('/watch/')) {
                    track = showName || 'Netflix';
                    artist = 'Netflix';
                }

                var ogImg = document.querySelector('meta[property="og:image"]');
                if (ogImg && ogImg.content) {
                    imgUrl = ogImg.content;
                } else {
                    var posterImg = document.querySelector('.previewModal--boxart, .boxart-image, [data-uia="video-canvas"] img, img.title-logo, .billboard-row img');
                    if (posterImg && posterImg.src) {
                        imgUrl = posterImg.src;
                    }
                }

                if (v) {
                    isPlaying = (!v.paused && !v.ended && v.currentTime > 0) ? 'playing' : 'paused';
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
            } else if (url.includes('netflix.com')) {
                service = 'netflix';
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

        let chromiumBrowsers = [
            ("Brave Browser", hasBrave, "Brave"),
            ("Google Chrome", hasChrome, "Chrome"),
            ("Arc", hasArc, "Arc"),
            ("Microsoft Edge", hasEdge, "Edge")
        ]

        // 1. Actively playing native apps
        if hasSpotify {
            let src = """
            try
                tell application "Spotify"
                    if player state is playing then
                        set trackName to (name of current track as text)
                        set trackArtist to (artist of current track as text)
                        set curPos to (player position)
                        set curDur to (duration of current track) / 1000
                        return "SpotifyNative|" & trackName & "|" & trackArtist & "|playing|none|" & curPos & "|" & curDur & "|spotify"
                    end if
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        if hasMusic {
            let src = """
            try
                tell application "Music"
                    if (player state as string) is "playing" then
                        set trackName to ""
                        try
                            set trackName to (name of current track as text)
                        end try
                        set trackArtist to ""
                        try
                            if (artist of current track) is not missing value then
                                set trackArtist to (artist of current track as text)
                            end if
                        end try
                        set curPos to 0
                        try
                            if (player position) is not missing value then
                                set curPos to (player position)
                            end if
                        end try
                        set curDur to 0
                        try
                            if (duration of current track) is not missing value then
                                set curDur to (duration of current track)
                            end if
                        end try
                        return "MusicNative|" & trackName & "|" & trackArtist & "|playing|none|" & curPos & "|" & curDur & "|applemusic"
                    end if
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        // 2. Actively playing browser tabs (only for currently running browsers)
        for (appName, isRunning, tag) in chromiumBrowsers where isRunning {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "\(appName)"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
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
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        if hasSafari {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "Safari"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
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
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        // 3. Actively playing MediaRemote (covers installed Netflix web app / PWA, QuickTime, Podcasts, etc.)
        if let getInfo = Self.mrGetNowPlayingInfo {
            let sema = DispatchSemaphore(value: 0)
            var mediaRemoteActive = false
            getInfo(DispatchQueue.global(qos: .userInitiated)) { [weak self] dict in
                if let d = dict as? [String: Any], let self = self {
                    let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
                    if rate > 0 {
                        mediaRemoteActive = self.parseMediaRemoteInfo(d)
                    }
                }
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 0.12)
            if mediaRemoteActive {
                return
            }
        }

        // 4. Paused browser tabs (only for currently running browsers)
        for (appName, isRunning, tag) in chromiumBrowsers where isRunning {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "\(appName)"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
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
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        if hasSafari {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "Safari"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
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
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        // 5. Paused native apps
        if hasSpotify {
            let src = """
            try
                tell application "Spotify"
                    set trackName to (name of current track as text)
                    set trackArtist to (artist of current track as text)
                    set curPos to (player position)
                    set curDur to (duration of current track) / 1000
                    return "SpotifyNative|" & trackName & "|" & trackArtist & "|paused|none|" & curPos & "|" & curDur & "|spotify"
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        if hasMusic {
            let src = """
            try
                tell application "Music"
                    set trackName to ""
                    try
                        set trackName to (name of current track as text)
                    end try
                    set trackArtist to ""
                    try
                        if (artist of current track) is not missing value then
                            set trackArtist to (artist of current track as text)
                        end if
                    end try
                    set curPos to 0
                    try
                        if (player position) is not missing value then
                            set curPos to (player position)
                        end if
                    end try
                    set curDur to 0
                    try
                        if (duration of current track) is not missing value then
                            set curDur to (duration of current track)
                        end if
                    end try
                    return "MusicNative|" & trackName & "|" & trackArtist & "|paused|none|" & curPos & "|" & curDur & "|applemusic"
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        // 6. Paused MediaRemote (if any)
        if let getInfo = Self.mrGetNowPlayingInfo {
            let sema = DispatchSemaphore(value: 0)
            var mediaRemoteHandled = false
            getInfo(DispatchQueue.global(qos: .userInitiated)) { [weak self] dict in
                if let d = dict as? [String: Any], let self = self {
                    mediaRemoteHandled = self.parseMediaRemoteInfo(d)
                }
                sema.signal()
            }
            _ = sema.wait(timeout: .now() + 0.12)
            if mediaRemoteHandled {
                return
            }
        }

        setNotPlaying()
    }
    
    private static let artworkCache = NSCache<NSString, NSImage>()
    private var consecutiveNotPlayingCount = 0
    
    private func parseMediaRemoteInfo(_ d: [String: Any]) -> Bool {
        let rawTitle = (d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return false }
        
        let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0
        let duration = d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0
        let elapsed = d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
        let timestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
        let rawArtist = (d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAlbum = (d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        var title = rawTitle
        var artist = rawArtist
        var service: MediaService = .other
        
        let isNetflix = title.localizedCaseInsensitiveContains("Netflix") ||
                        artist.localizedCaseInsensitiveContains("Netflix") ||
                        rawAlbum.localizedCaseInsensitiveContains("Netflix") ||
                        NSWorkspace.shared.runningApplications.contains(where: {
                            ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("netflix") ||
                            ($0.localizedName ?? "").localizedCaseInsensitiveContains("netflix")
                        })
        
        if isNetflix {
            service = .netflix
            title = title
                .replacingOccurrences(of: " - Netflix", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " | Netflix", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Watch ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            if title.lowercased() == "home" || title.lowercased() == "browse" || title.isEmpty {
                // If just browsing and not playing, don't show as playing
                if rate == 0 {
                    return false
                }
                title = "Netflix"
            }
            if artist.isEmpty {
                artist = rawAlbum.isEmpty ? "Netflix" : rawAlbum
            }
        } else if title.localizedCaseInsensitiveContains("YouTube") || artist.localizedCaseInsensitiveContains("YouTube") {
            service = .youtube
        } else if title.localizedCaseInsensitiveContains("Spotify") || artist.localizedCaseInsensitiveContains("Spotify") {
            service = .spotify
        } else if title.localizedCaseInsensitiveContains("Apple Music") || artist.localizedCaseInsensitiveContains("Apple Music") {
            service = .appleMusic
        } else if rate == 0 && duration == 0 {
            return false
        }
        
        var artwork: NSImage? = nil
        if let artData = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, let img = NSImage(data: artData) {
            artwork = img
        }
        
        let timeSince = Date().timeIntervalSince(timestamp)
        let calculatedPos = max(0, rate > 0 ? (elapsed + timeSince * rate) : elapsed)
        let currentPos = duration > 0 ? min(calculatedPos, duration) : calculatedPos
        
        Task { @MainActor in
            self.consecutiveNotPlayingCount = 0
            self.currentSource = service == .netflix ? "NetflixApp" : "MediaRemote"
            self.title = title
            self.artist = artist
            self.isPlaying = rate > 0
            self.isYouTube = service == .youtube
            self.isNetflix = service == .netflix
            self.mediaService = service
            if !self.isScrubbing && Date() >= self.seekLockUntil {
                self.currentTime = currentPos
            }
            self.duration = duration
            if let artwork = artwork {
                self.artworkImage = artwork
            } else {
                self.loadAppIcon(for: self.currentSource)
            }
        }
        return true
    }
    
    private func executeScriptAndParse(_ resultString: String) {
        guard !resultString.isEmpty else {
            setNotPlaying()
            return
        }
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
            let newIsNetflix = sourceApp.localizedCaseInsensitiveContains("Netflix") || imgUrlString.contains("netflix.com") || imgUrlString.contains("nflxso.net") || imgUrlString.contains("nflxext.com")
            
            let serviceTag = parts.count >= 8 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
            let newService: MediaService
            if serviceTag == "spotify" || sourceApp == "SpotifyNative" || imgUrlString.contains("spotify.com") {
                newService = .spotify
            } else if serviceTag == "youtube" || newIsYouTube {
                newService = .youtube
            } else if serviceTag == "applemusic" || sourceApp == "MusicNative" {
                newService = .appleMusic
            } else if serviceTag == "netflix" || newIsNetflix {
                newService = .netflix
            } else {
                newService = .other
            }
            
            Task { @MainActor in
                self.consecutiveNotPlayingCount = 0
                self.currentSource = sourceApp
                self.title = newTitle
                self.artist = newArtist
                self.isPlaying = newIsPlaying
                self.isYouTube = newService == .youtube
                self.isNetflix = newService == .netflix
                self.mediaService = newService
                if !self.isScrubbing && Date() >= self.seekLockUntil {
                    if sourceApp != "MusicNative" || newCurPos > 0 {
                        self.currentTime = newCurPos
                    }
                }
                self.duration = newDuration
                
                if imgUrlString != "none" && !imgUrlString.isEmpty {
                    if let cached = Self.artworkCache.object(forKey: imgUrlString as NSString) {
                        self.artworkImage = cached
                    } else {
                        if let url = URL(string: imgUrlString) {
                            self.lastArtworkURL = imgUrlString
                            var request = URLRequest(url: url)
                            request.timeoutInterval = 8.0
                            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                                guard let self = self, let data = data, let img = NSImage(data: data) else { return }
                                Self.artworkCache.setObject(img, forKey: imgUrlString as NSString)
                                Task { @MainActor in
                                    if self.lastArtworkURL == imgUrlString || self.artworkImage == nil {
                                        self.artworkImage = img
                                    }
                                }
                            }.resume()
                        }
                    }
                } else {
                    self.lastArtworkURL = ""
                    self.loadAppIcon(for: sourceApp)
                }
            }

            if sourceApp == "MusicNative" || (sourceApp == "SpotifyNative" && newCurPos == 0) {
                if let getInfo = Self.mrGetNowPlayingInfo {
                    getInfo(DispatchQueue.global(qos: .userInitiated)) { [weak self] dict in
                        guard let self = self, let d = dict as? [String: Any] else { return }
                        let elapsed = d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0
                        let rate = d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? (newIsPlaying ? 1.0 : 0.0)
                        let timestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
                        let timeSince = Date().timeIntervalSince(timestamp)
                        let calculatedPos = max(0, rate > 0 ? (elapsed + timeSince * rate) : elapsed)
                        
                        Task { @MainActor in
                            if !self.isScrubbing && Date() >= self.seekLockUntil {
                                if self.duration > 0 {
                                    self.currentTime = min(calculatedPos, self.duration)
                                } else {
                                    self.currentTime = calculatedPos
                                }
                            }
                        }
                    }
                }
            }
        } else {
            setNotPlaying()
        }
    }
    
    private func loadAppIcon(for sourceApp: String) {
        if mediaService == .netflix || sourceApp.localizedCaseInsensitiveContains("Netflix") {
            let runningApps = NSWorkspace.shared.runningApplications
            if let netflixApp = runningApps.first(where: {
                ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("netflix") ||
                ($0.localizedName ?? "").localizedCaseInsensitiveContains("netflix")
            }), let bundleUrl = netflixApp.bundleURL {
                let img = NSWorkspace.shared.icon(forFile: bundleUrl.path)
                Self.artworkCache.setObject(img, forKey: "netflixAppIcon" as NSString)
                self.artworkImage = img
                return
            }
            
            let possibleAppPaths = [
                "/Users/\(NSUserName())/Applications/Netflix.app",
                "/Users/\(NSUserName())/Applications/Chrome Apps.localized/Netflix.app",
                "/Applications/Netflix.app"
            ]
            for path in possibleAppPaths {
                if FileManager.default.fileExists(atPath: path) {
                    let img = NSWorkspace.shared.icon(forFile: path)
                    Self.artworkCache.setObject(img, forKey: "netflixAppIcon" as NSString)
                    self.artworkImage = img
                    return
                }
            }
        }

        let bundleId: String
        if sourceApp == "SpotifyNative" { bundleId = "com.spotify.client" }
        else if sourceApp == "MusicNative" { bundleId = "com.apple.Music" }
        else if sourceApp == "Brave" { bundleId = "com.brave.Browser" }
        else if sourceApp == "Chrome" { bundleId = "com.google.Chrome" }
        else if sourceApp == "Arc" { bundleId = "company.thebrowser.Browser" }
        else if sourceApp == "Edge" { bundleId = "com.microsoft.edgemac" }
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
                self.isNetflix = false
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
    
    private typealias MRSendCommandFunc = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let mediaRemoteHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    private static let mrSendCommand: MRSendCommandFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: MRSendCommandFunc.self)
    }()
    
    func seek(to seconds: Double) {
        self.currentTime = seconds
        self.seekLockUntil = Date().addingTimeInterval(1.2)
        let source = self.currentSource
        let runningApps = NSWorkspace.shared.runningApplications
        
        let hasBrave = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.brave.Browser" }
        let hasChrome = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.google.Chrome" }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "") == "company.thebrowser.Browser" }
        let hasEdge = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.microsoft.edgemac" }
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
                        if player state is not stopped then
                            set player position to \(seconds)
                        end if
                    end tell
                end try
                """
            } else if source == "NetflixApp" || source == "MediaRemote" {
                if let sendCmd = Self.mrSendCommand {
                    let dict: [String: Any] = ["kMRMediaRemoteOptionPlaybackPosition": seconds]
                    _ = sendCmd(11, dict as CFDictionary)
                }
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
                    ("Arc", hasArc),
                    ("Microsoft Edge", hasEdge)
                ]
                
                for (b, isRunning) in browsers where isRunning {
                    scriptSource += """
                    try
                        tell application "\(b)"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
                                        tell t to execute javascript "\(escapedJsSeek)"
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
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
                                        do JavaScript "\(escapedJsSeek)" in t
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    
                    """
                }
            }

            if !scriptSource.isEmpty, let script = NSAppleScript(source: scriptSource) {
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
        
        let hasBrave = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.brave.Browser" }
        let hasChrome = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.google.Chrome" }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "") == "company.thebrowser.Browser" }
        let hasEdge = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.microsoft.edgemac" }
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
            } else if source == "NetflixApp" || source == "MediaRemote" {
                let cmdCode: Int32
                if command == "playpause" { cmdCode = 2 }
                else if command == "next track" { cmdCode = 4 }
                else if command == "previous track" { cmdCode = 5 }
                else { cmdCode = 2 }
                _ = Self.mrSendCommand?(cmdCode, nil)
            } else {
                let jsCmd = """
                (function() {
                    var cmd = '\(command)';
                    if (cmd === 'playpause') {
                        var nfPlayBtn = document.querySelector('[data-uia="control-play-pause-play"], [data-uia="control-play-pause-pause"], [data-uia="control-play-pause"], .button-nfVideosPlay, .button-nfVideosPause');
                        var ytPlayBtn = document.querySelector('.ytp-play-button, .play-pause-button.ytmusic-player-bar, #play-pause-button, [data-testid="control-button-playpause"]');
                        if (nfPlayBtn) {
                            nfPlayBtn.click();
                        } else if (ytPlayBtn) {
                            ytPlayBtn.click();
                        } else {
                            var videos = Array.from(document.querySelectorAll('video'));
                            var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                            if (v) {
                                if (v.paused) v.play(); else v.pause();
                            }
                        }
                    } else if (cmd === 'next track') {
                        var nfForwardBtn = document.querySelector('[data-uia="control-fast-forward"], [data-uia="control-seek-forward"], [data-uia="control-skip-forward"], .button-nfVideosFastForward');
                        var nextBtn = document.querySelector('.ytp-next-button, .next-button.ytmusic-player-bar, [data-testid="control-button-skip-forward"]');
                        if (nfForwardBtn) {
                            nfForwardBtn.click();
                        } else {
                            var videos = Array.from(document.querySelectorAll('video'));
                            var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                            if (v && isFinite(v.duration)) {
                                v.currentTime = Math.min(v.duration, v.currentTime + 10);
                            } else if (nextBtn) {
                                nextBtn.click();
                            }
                        }
                    } else if (cmd === 'previous track') {
                        var nfRewindBtn = document.querySelector('[data-uia="control-seek-back"], [data-uia="control-fast-rewind"], [data-uia="control-skip-back"], .button-nfVideosRewind');
                        var prevBtn = document.querySelector('.ytp-prev-button, .previous-button.ytmusic-player-bar, [data-testid="control-button-skip-back"]');
                        if (nfRewindBtn) {
                            nfRewindBtn.click();
                        } else {
                            var videos = Array.from(document.querySelectorAll('video'));
                            var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                            if (v) {
                                if (v.currentTime > 3) {
                                    v.currentTime = 0;
                                } else {
                                    v.currentTime = Math.max(0, v.currentTime - 10);
                                }
                            } else if (prevBtn) {
                                prevBtn.click();
                            }
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
                    ("Arc", hasArc),
                    ("Microsoft Edge", hasEdge)
                ]
                
                for (b, isRunning) in browsers where isRunning {
                    scriptSource += """
                    try
                        tell application "\(b)"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
                                        tell t to execute javascript "\(escapedJsCmd)"
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
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com") then
                                        do JavaScript "\(escapedJsCmd)" in t
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    
                    """
                }
            }

            if !scriptSource.isEmpty, let script = NSAppleScript(source: scriptSource) {
                script.executeAndReturnError(nil)
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
                self?.fetchNowPlayingInfo()
            }
        }
    }
}