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
            return Color(red: 0.22, green: 0.86, blue: 0.45)
        case .youtube:
            return Color(red: 255/255.0, green: 51/255.0, blue: 51/255.0)
        case .appleMusic:
            return Color(red: 250/255.0, green: 45/255.0, blue: 72/255.0)
        case .netflix:
            return Color(red: 229/255.0, green: 9/255.0, blue: 20/255.0)
        case .other:
            return Color(red: 0.22, green: 0.86, blue: 0.45)
        }
    }
    
    private var timer: Timer?
    private var progressTimer: Timer?
    private var lastArtworkURL: String = ""
    private var seekLockUntil: Date = .distantPast
    private var consecutiveNotPlayingCount = 0
    private static let artworkCache = NSCache<NSString, NSImage>()
    
    // MARK: - MediaRemote Private Framework
    private static let mediaRemoteHandle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
    
    private typealias MRRegisterForNotificationsFunc = @convention(c) (DispatchQueue) -> Void
    private static let mrRegisterForNotifications: MRRegisterForNotificationsFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") else { return nil }
        return unsafeBitCast(sym, to: MRRegisterForNotificationsFunc.self)
    }()

    private typealias MRGetNowPlayingInfoFunc = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private static let mrGetNowPlayingInfo: MRGetNowPlayingInfoFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else { return nil }
        return unsafeBitCast(sym, to: MRGetNowPlayingInfoFunc.self)
    }()

    private typealias MRGetIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private static let mrGetIsPlaying: MRGetIsPlayingFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") else { return nil }
        return unsafeBitCast(sym, to: MRGetIsPlayingFunc.self)
    }()
    
    private typealias MRGetClientFunc = @convention(c) (DispatchQueue, @escaping (AnyObject?) -> Void) -> Void
    private static let mrGetNowPlayingClient: MRGetClientFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingClient") else { return nil }
        return unsafeBitCast(sym, to: MRGetClientFunc.self)
    }()
    
    private typealias ClientGetStrFunc = @convention(c) (AnyObject) -> CFString?
    private static let mrClientGetBundleId: ClientGetStrFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRNowPlayingClientGetBundleIdentifier") else { return nil }
        return unsafeBitCast(sym, to: ClientGetStrFunc.self)
    }()
    
    private static let mrClientGetDisplayName: ClientGetStrFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRNowPlayingClientGetDisplayName") else { return nil }
        return unsafeBitCast(sym, to: ClientGetStrFunc.self)
    }()
    
    private typealias ClientGetPIDFunc = @convention(c) (AnyObject) -> pid_t
    private static let mrClientGetPID: ClientGetPIDFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRNowPlayingClientGetProcessIdentifier") else { return nil }
        return unsafeBitCast(sym, to: ClientGetPIDFunc.self)
    }()

    private typealias MRSendCommandFunc = @convention(c) (Int32, CFDictionary?) -> Bool
    private static let mrSendCommand: MRSendCommandFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteSendCommand") else { return nil }
        return unsafeBitCast(sym, to: MRSendCommandFunc.self)
    }()
    
    private typealias MRSetElapsedTimeFunc = @convention(c) (Double) -> Void
    private static let mrSetElapsedTime: MRSetElapsedTimeFunc? = {
        guard let handle = mediaRemoteHandle, let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") else { return nil }
        return unsafeBitCast(sym, to: MRSetElapsedTimeFunc.self)
    }()
    
    init() {
        Self.mrRegisterForNotifications?(DispatchQueue.global(qos: .userInitiated))
        setupNotificationObservers()
        startPolling()
    }
    
    private func setupNotificationObservers() {
        let notifCenter = NotificationCenter.default
        let mrNotifications = [
            "kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            "kMRNowPlayingPlaybackQueueChangedNotification"
        ]
        for notifName in mrNotifications {
            notifCenter.addObserver(forName: NSNotification.Name(notifName), object: nil, queue: nil) { [weak self] _ in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.fetchNowPlayingInfo()
                }
            }
        }
    }
    
    private func startPolling() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .userInitiated).async {
                self?.fetchNowPlayingInfo()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        self.timer = t

        let pt = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if self.isPlaying && !self.isScrubbing && self.duration > 0 {
                    let nextTime = self.currentTime + 0.1
                    if nextTime <= self.duration {
                        self.currentTime = nextTime
                    }
                }
            }
        }
        RunLoop.main.add(pt, forMode: .common)
        self.progressTimer = pt

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
        if let getInfo = Self.mrGetNowPlayingInfo {
            if let getClient = Self.mrGetNowPlayingClient {
                getClient(DispatchQueue.global(qos: .userInitiated)) { [weak self] client in
                    var clientBundleId = ""
                    var clientDisplayName = ""
                    var clientPID: pid_t = 0
                    if let client = client {
                        clientBundleId = (Self.mrClientGetBundleId?(client) as String?) ?? ""
                        clientDisplayName = (Self.mrClientGetDisplayName?(client) as String?) ?? ""
                        clientPID = Self.mrClientGetPID?(client) ?? 0
                    }
                    
                    getInfo(DispatchQueue.global(qos: .userInitiated)) { [weak self] dict in
                        guard let self = self else { return }
                        if let d = dict as? [String: Any],
                           self.parseMediaRemoteInfo(d, clientBundleId: clientBundleId, clientDisplayName: clientDisplayName, clientPID: clientPID) {
                            return
                        }
                        self.checkFallbacks()
                    }
                }
            } else {
                getInfo(DispatchQueue.global(qos: .userInitiated)) { [weak self] dict in
                    guard let self = self else { return }
                    if let d = dict as? [String: Any],
                       self.parseMediaRemoteInfo(d, clientBundleId: "", clientDisplayName: "", clientPID: 0) {
                        return
                    }
                    self.checkFallbacks()
                }
            }
        } else {
            checkFallbacks()
        }
    }
    
    // MARK: - Browser Scraper JS
    // IMPORTANT: No bare 'ytPlayer' variable references; all undefined-risk vars
    // are declared with 'var' before use. This prevents JS exceptions in non-YT tabs.
    private var browserScraperJS: String {
        // We use single-backslash in Swift string, the escaping happens in checkFallbacks()
        return #"""
        (function() {
            var url = window.location.href;
            var track = '', artist = '', isPlaying = 'paused', imgUrl = '', curPos = 0, curDur = 0;
            var service = 'other';

            function isMediaPlaying(el) {
                if (!el) return false;
                return (!el.paused && !el.ended && el.currentTime > 0 && el.readyState > 1);
            }
            function findActiveVideo() {
                var videos = Array.from(document.querySelectorAll('video'));
                return videos.find(function(x) { return isMediaPlaying(x); })
                    || document.querySelector('.html5-main-video')
                    || videos[0]
                    || null;
            }
            function findActiveAudio() {
                var audios = Array.from(document.querySelectorAll('audio'));
                return audios.find(function(x) { return !x.paused && !x.ended; }) || null;
            }
            function parseTimeStr(s) {
                var p = (s || '').trim().split(':').map(Number);
                if (p.length === 2) return p[0]*60 + p[1];
                if (p.length === 3) return p[0]*3600 + p[1]*60 + p[2];
                return 0;
            }
            function getText(el) {
                if (!el) return '';
                return (el.innerText || el.textContent || '').trim();
            }

            var v = findActiveVideo();
            var a = findActiveAudio();
            var media = v || a;

            if (url.indexOf('music.youtube.com') !== -1) {
                service = 'youtube';
                var ytmTitleEl = document.querySelector('.title.ytmusic-player-bar, yt-formatted-string.title.ytmusic-player-bar');
                track = ytmTitleEl ? getText(ytmTitleEl) : document.title.replace(/ - YouTube Music$/, '').trim();
                var ytmArtistEl = document.querySelector('.ytmusic-player-bar .byline a:first-child, .ytmusic-player-bar .subtitle a, .ytmusic-player-bar .byline');
                artist = ytmArtistEl ? getText(ytmArtistEl) : 'YouTube Music';
                var ytmImgEl = document.querySelector('.ytmusic-player-bar img.image, .thumbnail-wrapper img, ytmusic-player-bar img');
                if (ytmImgEl && ytmImgEl.src) imgUrl = ytmImgEl.src;
                var ytmPlayBtn = document.querySelector('.play-pause-button.ytmusic-player-bar, #play-pause-button');
                if (v) {
                    isPlaying = isMediaPlaying(v) ? 'playing' : 'paused';
                } else if (ytmPlayBtn) {
                    var ytmLabel = (ytmPlayBtn.getAttribute('aria-label') || '').toLowerCase();
                    isPlaying = (ytmLabel.indexOf('pause') !== -1) ? 'playing' : 'paused';
                }

            } else if (url.indexOf('youtube.com') !== -1 || url.indexOf('youtu.be') !== -1) {
                service = 'youtube';
                var ytTitleEl = document.querySelector('h1.ytd-watch-metadata yt-formatted-string, #title h1 yt-formatted-string, .ytp-title-link, h1.title');
                track = ytTitleEl ? getText(ytTitleEl) : document.title.replace(/ - YouTube$/, '').trim();
                var ytArtistEl = document.querySelector('#owner ytd-channel-name yt-formatted-string a, ytd-channel-name a, #channel-name a');
                artist = ytArtistEl ? getText(ytArtistEl) : 'YouTube';

                // Strict play state using video element + player container
                var ytPlayerEl = document.querySelector('.html5-video-player');
                if (v) {
                    var strictPlaying = isMediaPlaying(v);
                    if (ytPlayerEl && ytPlayerEl.classList.contains('paused-mode')) {
                        strictPlaying = false;
                    }
                    isPlaying = strictPlaying ? 'playing' : 'paused';
                } else {
                    isPlaying = 'paused';
                }

                // Thumbnail from video ID
                var ytVideoId = '';
                try {
                    var sp = new URLSearchParams(window.location.search);
                    if (sp.has('v')) ytVideoId = sp.get('v');
                } catch(e2) {}
                if (!ytVideoId && url.indexOf('/shorts/') !== -1) {
                    var shortParts = url.split('/shorts/');
                    if (shortParts.length > 1) ytVideoId = shortParts[1].split('?')[0].split('/')[0];
                }
                if (!ytVideoId && url.indexOf('youtu.be/') !== -1) {
                    var shParts = url.split('youtu.be/');
                    if (shParts.length > 1) ytVideoId = shParts[1].split('?')[0].split('/')[0];
                }
                if (ytVideoId) imgUrl = 'https://i.ytimg.com/vi/' + ytVideoId + '/hqdefault.jpg';

            } else if (url.indexOf('spotify.com') !== -1) {
                service = 'spotify';
                var spTitleEl = document.querySelector('[data-testid="context-item-link"], a[data-testid="context-item-info-title"]');
                if (!spTitleEl) spTitleEl = document.querySelector('[data-testid="now-playing-widget"] a');
                track = spTitleEl ? getText(spTitleEl) : '';

                var spArtistEl = document.querySelector('[data-testid="context-item-info-subtitles"] a, [data-testid="context-item-info-artist"]');
                if (!spArtistEl) spArtistEl = document.querySelector('[data-testid="now-playing-widget"] [data-testid="context-item-info-subtitles"]');
                if (spArtistEl) {
                    artist = getText(spArtistEl).replace(/[\r\n]+/g, ', ').trim();
                }

                var spPlayBtn = document.querySelector('button[data-testid="control-button-playpause"], [data-testid="control-button-playpause"]');
                if (spPlayBtn) {
                    var spLabel = (spPlayBtn.getAttribute('aria-label') || '').toLowerCase();
                    isPlaying = (spLabel.indexOf('pause') !== -1) ? 'playing' : 'paused';
                } else if (v) {
                    isPlaying = (!v.paused && !v.ended) ? 'playing' : 'paused';
                } else if (a) {
                    isPlaying = (!a.paused && !a.ended) ? 'playing' : 'paused';
                }

                var spImgEl = document.querySelector('img[data-testid="cover-art-image"], img[data-testid="context-item-image"]');
                if (!spImgEl) spImgEl = document.querySelector('[data-testid="now-playing-widget"] img');
                if (spImgEl && spImgEl.src) {
                    imgUrl = spImgEl.src;
                } else {
                    var spOgImg = document.querySelector('meta[property="og:image"]');
                    if (spOgImg) imgUrl = spOgImg.getAttribute('content') || '';
                }

                var spCurEl = document.querySelector('[data-testid="playback-position"]');
                var spDurEl = document.querySelector('[data-testid="playback-duration"]');
                if (spCurEl && spDurEl && spCurEl.textContent && spDurEl.textContent) {
                    curPos = parseTimeStr(spCurEl.textContent);
                    curDur = parseTimeStr(spDurEl.textContent);
                }
                if (!curPos && !curDur) {
                    var spInp = document.querySelector('[data-testid="playback-progressbar"] input');
                    if (spInp) {
                        curPos = Math.round(Number(spInp.value) / 1000);
                        curDur = Math.round(Number(spInp.max) / 1000);
                    }
                }

            } else if (url.indexOf('music.apple.com') !== -1) {
                service = 'applemusic';
                var amTitleEl = document.querySelector('.web-chrome-playback-lcd__sub-copy-scroll-inner-text-wrapper, [data-testid="lcd-song-title"], .lcd-label__primary');
                track = amTitleEl ? getText(amTitleEl) : document.title.replace(/ - Apple Music$/, '').trim();
                var amArtistEl = document.querySelector('.web-chrome-playback-lcd__sub-copy-scroll-inner-text-wrapper a, [data-testid="lcd-artist-name"], .lcd-label__secondary');
                artist = amArtistEl ? getText(amArtistEl) : 'Apple Music';
                var amImgEl = document.querySelector('.web-chrome-playback-lcd__artwork img, [data-testid="lcd-artwork"] img, .media-artwork-v2 img');
                if (amImgEl && amImgEl.src) imgUrl = amImgEl.src;
                if (!imgUrl) {
                    var amSrcEl = document.querySelector('.web-chrome-playback-lcd__artwork source, [data-testid="lcd-artwork"] source');
                    if (amSrcEl && amSrcEl.srcset) {
                        var amParts2 = amSrcEl.srcset.split(',');
                        imgUrl = amParts2[amParts2.length - 1].trim().split(' ')[0];
                    }
                }
                var amPlayBtn = document.querySelector('.web-chrome-playback-controls__play-pause-btn, [data-testid="play-pause-button"]');
                if (v && isMediaPlaying(v)) {
                    isPlaying = 'playing';
                } else if (a && !a.paused && !a.ended) {
                    isPlaying = 'playing';
                } else if (amPlayBtn) {
                    var amLabel2 = (amPlayBtn.getAttribute('aria-label') || '').toLowerCase();
                    isPlaying = (amLabel2.indexOf('pause') !== -1) ? 'playing' : 'paused';
                }

            } else if (url.indexOf('netflix.com') !== -1) {
                service = 'netflix';
                var nfTitleEl = document.querySelector('[data-uia="video-title"], .video-title, [data-uia="watch-video-title"]');
                var showName = '', episodeName = '';
                if (nfTitleEl) {
                    var h4el = nfTitleEl.querySelector('h4');
                    var nfSpans = Array.from(nfTitleEl.querySelectorAll('span')).map(function(s) { return getText(s); }).filter(Boolean);
                    if (h4el) {
                        showName = getText(h4el);
                        if (nfSpans.length > 0) episodeName = nfSpans.join(' - ');
                    } else if (nfSpans.length > 0) {
                        showName = nfSpans[0];
                        if (nfSpans.length > 1) episodeName = nfSpans.slice(1).join(' - ');
                    } else {
                        showName = getText(nfTitleEl);
                    }
                }
                if (!showName && document.title) showName = document.title.trim();
                showName = showName.replace(/^Watch\s+/i, '').replace(/\s*[\|\-\u2013\u2014]\s*Netflix.*$/i, '').trim();
                track = showName || 'Netflix';
                artist = episodeName || 'Netflix';
                if (v) isPlaying = (!v.paused && !v.ended) ? 'playing' : 'paused';
            }

            if (media && service !== 'spotify') {
                curPos = media.currentTime || 0;
                curDur = (isFinite(media.duration) && media.duration > 0) ? media.duration : 0;
            }

            if (track) {
                return track.trim() + '|' + artist.trim() + '|' + isPlaying + '|' + (imgUrl || 'none') + '|' + Math.round(curPos) + '|' + Math.round(curDur) + '|' + service;
            }
            return 'null';
        })();
        """#
    }
    
    private func checkFallbacks() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        // 1. Native Spotify
        let hasSpotify = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.spotify.client" }
        if hasSpotify {
            let src = """
            try
                tell application id "com.spotify.client"
                    set pState to (player state as string)
                    if pState is "playing" then
                        set trackName to (name of current track as text)
                        set trackArtist to (artist of current track as text)
                        set curPos to (player position)
                        set curDur to (duration of current track) / 1000
                        set trackArt to "none"
                        try
                            set trackArt to (artwork url of current track as text)
                        end try
                        return "SpotifyNative|" & trackName & "|" & trackArtist & "|playing|" & trackArt & "|" & curPos & "|" & curDur & "|spotify"
                    end if
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src), res.contains("|playing|") {
                executeScriptAndParse(res)
                return
            }
        }

        // 2. Native Apple Music
        let hasMusic = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        if hasMusic {
            let src = """
            try
                tell application id "com.apple.Music"
                    set pState to (player state as string)
                    if pState is "playing" then
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
            if let res = runIsolatedAppleScript(src), res.contains("|playing|") {
                executeScriptAndParse(res)
                return
            }
        }

        // 3. Browser scraping
        let scraperJS = browserScraperJS
        let escapedScraper = scraperJS
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let hasBrave = runningApps.contains { app in
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return bid.hasPrefix("com.brave") || name.localizedCaseInsensitiveContains("brave")
        }
        let hasChrome = runningApps.contains { app in
            let bid = app.bundleIdentifier ?? ""
            return bid.hasPrefix("com.google.Chrome") || (app.localizedName ?? "").localizedCaseInsensitiveContains("google chrome")
        }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("thebrowser") }
        let hasSafari = runningApps.contains { app in
            let bid = app.bundleIdentifier ?? ""
            return bid == "com.apple.Safari" || bid == "com.apple.SafariTechnologyPreview"
        }
        let hasEdge = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("edgemac") }

        let chromiumBrowsers = [
            ("Brave Browser", hasBrave, "Brave"),
            ("Google Chrome", hasChrome, "Chrome"),
            ("Arc", hasArc, "Arc"),
            ("Microsoft Edge", hasEdge, "Edge")
        ] as [(String, Bool, String)]

        for (appName, isRunning, tag) in chromiumBrowsers where isRunning {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "\(appName)"
                    set fallbackCandidate to "null"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com" or tabURL contains "music.apple.com" or tabURL contains "music.youtube.com") then
                                try
                                    set res to execute t javascript webScraper
                                    if res is not missing value and res is not "null" then
                                        if res contains "|playing|" then
                                            return "\(tag)|" & res
                                        else if fallbackCandidate is "null" then
                                            set fallbackCandidate to "\(tag)|" & res
                                        end if
                                    end if
                                on error
                                end try
                            end if
                        end repeat
                    end repeat
                    if fallbackCandidate is not "null" then
                        return fallbackCandidate
                    end if
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }

        // Safari
        if hasSafari {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "Safari"
                    set fallbackCandidate to "null"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com" or tabURL contains "music.apple.com" or tabURL contains "music.youtube.com") then
                                try
                                    set res to do JavaScript webScraper in t
                                    if res is not missing value and res is not "null" then
                                        if res contains "|playing|" then
                                            return "Safari|" & res
                                        else if fallbackCandidate is "null" then
                                            set fallbackCandidate to "Safari|" & res
                                        end if
                                    end if
                                on error
                                end try
                            end if
                        end repeat
                    end repeat
                    if fallbackCandidate is not "null" then
                        return fallbackCandidate
                    end if
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src) {
                executeScriptAndParse(res)
                return
            }
        }
        
        // 4. Brave PWA processes
        if let pwaResult = scrapeBravePWAProcesses(escapedScraper: escapedScraper) {
            executeScriptAndParse(pwaResult)
            return
        }

        setNotPlaying()
    }
    
    // MARK: - Brave PWA scraping
    // Brave PWAs (YouTube, Spotify, etc.) run as separate processes with bundle IDs
    // like "com.brave.Browser.app.<hash>". Normal browser tab iteration doesn't reach them.
    private func scrapeBravePWAProcesses(escapedScraper: String) -> String? {
        let runningApps = NSWorkspace.shared.runningApplications
        let pwaApps = runningApps.filter { app in
            let bid = app.bundleIdentifier ?? ""
            return bid.hasPrefix("com.brave.Browser.app.") || bid.hasPrefix("com.google.Chrome.app.")
        }
        guard !pwaApps.isEmpty else { return nil }
        
        for pwaApp in pwaApps {
            let appName = pwaApp.localizedName ?? ""
            let pid = pwaApp.processIdentifier
            
            let script = """
            tell application "System Events"
                set pwaProcess to first process whose unix id is \(pid)
                set pwaName to name of pwaProcess
            end tell
            try
                tell application pwaName
                    set webScraper to "\(escapedScraper)"
                    repeat with win in every window
                        try
                            repeat with t in every tab of win
                                try
                                    set res to execute t javascript webScraper
                                    if res is not missing value and res is not "null" then
                                        return "\(appName)|" & res
                                    end if
                                on error
                                end try
                            end repeat
                        on error
                        end try
                    end repeat
                end tell
            on error
            end try
            """
            
            if let res = runIsolatedAppleScript(script), !res.isEmpty, res != "null" {
                return res
            }
        }
        return nil
    }
    
    // MARK: - MediaRemote Parsing
    private func parseMediaRemoteInfo(
        _ d: [String: Any],
        clientBundleId: String,
        clientDisplayName: String,
        clientPID: pid_t
    ) -> Bool {
        let rawTitle = (d["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return false }
        
        let rateVal = (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue ?? (d["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0)
        let isPlayingBool = rateVal > 0
        let duration = (d["kMRMediaRemoteNowPlayingInfoDuration"] as? NSNumber)?.doubleValue ?? (d["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0)
        let elapsed = (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? NSNumber)?.doubleValue ?? (d["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0)
        let timestamp = d["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date ?? Date()
        let rawArtist = (d["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawAlbum = (d["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        
        var runningApp: NSRunningApplication?
        if clientPID > 0 {
            runningApp = NSRunningApplication(processIdentifier: clientPID)
        }
        let appName = runningApp?.localizedName ?? clientDisplayName
        let fullBundleId = runningApp?.bundleIdentifier ?? clientBundleId
        
        var title = rawTitle
        var artist = rawArtist
        var service: MediaService = .other
        
        let isYouTubeService = clientDisplayName.localizedCaseInsensitiveContains("YouTube") ||
                        appName.localizedCaseInsensitiveContains("YouTube") ||
                        fullBundleId.localizedCaseInsensitiveContains("youtube") ||
                        fullBundleId.localizedCaseInsensitiveContains("agimnkijcaahngcdmfeangaknmldooml") ||
                        fullBundleId.localizedCaseInsensitiveContains("cinhimbnkkaohjvfdleckmgagpcbmegf") ||
                        rawAlbum.localizedCaseInsensitiveContains("YouTube")
        
        let isNetflixService = clientDisplayName.localizedCaseInsensitiveContains("Netflix") ||
                        appName.localizedCaseInsensitiveContains("Netflix") ||
                        fullBundleId.localizedCaseInsensitiveContains("netflix") ||
                        rawAlbum.localizedCaseInsensitiveContains("Netflix")
        
        let isSpotifyService = clientDisplayName.localizedCaseInsensitiveContains("Spotify") ||
                        appName.localizedCaseInsensitiveContains("Spotify") ||
                        fullBundleId.localizedCaseInsensitiveContains("spotify") ||
                        fullBundleId.localizedCaseInsensitiveContains("pjibgflleapemflmbggkgajjjonlganj")
        
        let isAppleMusicService = (clientDisplayName == "Music" || appName == "Music" || fullBundleId == "com.apple.Music")
        
        if isYouTubeService {
            service = .youtube
            title = title
                .replacingOccurrences(of: " - YouTube", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " - YouTube Music", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if artist.isEmpty || artist == appName {
                artist = rawAlbum.isEmpty ? "YouTube" : rawAlbum
            }
        } else if isNetflixService {
            service = .netflix
            title = title
                .replacingOccurrences(of: " - Netflix", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " | Netflix", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "Watch ", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty || title.lowercased() == "home" || title.lowercased() == "browse" {
                title = "Netflix"
            }
            if artist.isEmpty {
                artist = rawAlbum.isEmpty ? "Netflix" : rawAlbum
            }
        } else if isSpotifyService {
            service = .spotify
        } else if isAppleMusicService {
            service = .appleMusic
        } else {
            service = .other
        }
        
        // If we can't identify the service and not playing, fall through to browser fallbacks
        if !isPlayingBool && service == .other {
            return false
        }
        
        // Artwork extraction
        var artwork: NSImage? = nil
        if let artData = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, !artData.isEmpty, let img = NSImage(data: artData) {
            artwork = img
        }
        
        if service == .youtube {
            let cacheKey = "yt_\(title)" as NSString
            if let cached = Self.artworkCache.object(forKey: cacheKey) {
                artwork = cached
            } else if let art = artwork {
                Self.artworkCache.setObject(art, forKey: cacheKey)
            } else {
                DispatchQueue.global(qos: .background).async { [weak self] in
                    if let ytThumbUrl = self?.fetchYouTubeThumbnailUrl() {
                        self?.fetchAndCacheImage(from: ytThumbUrl, cacheKey: cacheKey as String)
                    }
                }
            }
        }
        
        var finalDuration = duration
        let timeSince = Date().timeIntervalSince(timestamp)
        let calculatedPos = max(0, isPlayingBool ? (elapsed + timeSince * (rateVal > 0 ? rateVal : 1.0)) : elapsed)
        let finalPos = duration > 0 ? min(calculatedPos, duration) : calculatedPos
        
        let isNativeMusicRunning = NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        if service == .appleMusic && isNativeMusicRunning {
            if finalDuration <= 0 || self.duration <= 0 {
                let (_, musicDur) = self.fetchAppleMusicPositionAndDuration()
                if musicDur > 0 {
                    finalDuration = musicDur
                }
            }
            if artwork == nil {
                artwork = self.getOrFetchAppleMusicArtwork(for: title, artist: artist)
            }
        }
        
        let finalTitle = title
        let finalArtist = artist
        let finalService = service
        let finalArtwork = artwork
        let finalAppName = appName
        let finalBundleId = fullBundleId
        
        Task { @MainActor in
            self.consecutiveNotPlayingCount = 0
            self.currentSource = finalAppName.isEmpty ? "MediaRemote" : finalAppName
            let titleChanged = (self.title != finalTitle)
            self.title = finalTitle
            self.artist = finalArtist
            self.isPlaying = isPlayingBool
            self.isYouTube = finalService == .youtube
            self.isNetflix = finalService == .netflix
            self.mediaService = finalService
            if !self.isScrubbing && Date() >= self.seekLockUntil {
                if titleChanged {
                    self.currentTime = finalPos
                } else if !self.isPlaying || abs(self.currentTime - finalPos) > 2.0 {
                    self.currentTime = finalPos
                }
            }
            self.duration = finalDuration
            if let artwork = finalArtwork {
                self.artworkImage = artwork
            } else if finalService != .youtube || self.artworkImage == nil {
                self.loadAppIcon(for: self.currentSource, bundleId: finalBundleId)
            }
        }
        return true
    }
    
    private func fetchAppleMusicPositionAndDuration() -> (Double, Double) {
        let isMusicRunning = NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        guard isMusicRunning else { return (0, 0) }
        let scriptSrc = """
        try
            tell application id "com.apple.Music"
                set curDur to 0
                if (duration of current track) is not missing value then
                    set curDur to (duration of current track)
                end if
                set curPos to 0
                try
                    if (player position) is not missing value then
                        set curPos to (player position)
                    end if
                end try
                return (curPos as string) & "|" & (curDur as string)
            end tell
        on error
            return "0|0"
        end try
        """
        guard let script = NSAppleScript(source: scriptSrc) else { return (0, 0) }
        var error: NSDictionary?
        let desc = script.executeAndReturnError(&error)
        if let str = desc.stringValue, !str.isEmpty {
            let parts = str.components(separatedBy: "|")
            if parts.count >= 2 {
                let pos = Double(parts[0]) ?? 0
                let dur = Double(parts[1]) ?? 0
                return (pos, dur)
            }
        }
        return (0, 0)
    }
    
    private func getOrFetchAppleMusicArtwork(for title: String, artist: String) -> NSImage? {
        let isMusicRunning = NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        guard isMusicRunning else { return nil }
        let cacheKey = "AppleMusic_\(title)_\(artist)" as NSString
        if let cached = Self.artworkCache.object(forKey: cacheKey) {
            return cached
        }
        let scriptSrc = """
        try
            tell application id "com.apple.Music"
                if (count of artworks of current track) > 0 then
                    return raw data of artwork 1 of current track
                end if
            end tell
        on error
            return missing value
        end try
        """
        guard let script = NSAppleScript(source: scriptSrc) else { return nil }
        var error: NSDictionary?
        let desc = script.executeAndReturnError(&error)
        let data = desc.data
        if !data.isEmpty, let img = NSImage(data: data) {
            Self.artworkCache.setObject(img, forKey: cacheKey)
            return img
        }
        return nil
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
            
            let serviceTag = parts.count >= 8 ? parts[7].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
            let newService: MediaService
            if serviceTag == "spotify" || sourceApp == "SpotifyNative" || imgUrlString.contains("spotify") || imgUrlString.contains("scdn.co") {
                newService = .spotify
            } else if serviceTag == "youtube" || imgUrlString.contains("youtube.com") || imgUrlString.contains("ytimg.com") || sourceApp.localizedCaseInsensitiveContains("youtube") {
                newService = .youtube
            } else if serviceTag == "applemusic" || sourceApp == "MusicNative" {
                newService = .appleMusic
            } else if serviceTag == "netflix" || imgUrlString.contains("netflix") || imgUrlString.contains("nflxso") {
                newService = .netflix
            } else {
                newService = .other
            }
            
            Task { @MainActor in
                self.consecutiveNotPlayingCount = 0
                self.currentSource = sourceApp
                let titleChanged = (self.title != newTitle)
                self.title = newTitle
                self.artist = newArtist
                self.isPlaying = newIsPlaying
                self.isYouTube = newService == .youtube
                self.isNetflix = newService == .netflix
                self.mediaService = newService
                if !self.isScrubbing && Date() >= self.seekLockUntil {
                    if titleChanged {
                        self.currentTime = newCurPos
                    } else if !self.isPlaying || abs(self.currentTime - newCurPos) > 2.0 {
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
                } else if newService == .appleMusic || sourceApp == "MusicNative" {
                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        guard let self = self else { return }
                        if let appleMusicArt = self.getOrFetchAppleMusicArtwork(for: newTitle, artist: newArtist) {
                            Task { @MainActor in self.artworkImage = appleMusicArt }
                        } else {
                            Task { @MainActor in
                                self.lastArtworkURL = ""
                                self.loadAppIcon(for: sourceApp)
                            }
                        }
                    }
                } else if newService == .youtube && imgUrlString == "none" {
                    DispatchQueue.global(qos: .background).async { [weak self] in
                        guard let self = self else { return }
                        if let thumbUrl = self.fetchYouTubeThumbnailUrl() {
                            self.fetchAndCacheImage(from: thumbUrl, cacheKey: "yt_\(newTitle)")
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
    }
    
    private func loadAppIcon(for sourceApp: String, bundleId: String? = nil) {
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
        }

        let resolvedBundleId: String
        if let bid = bundleId, !bid.isEmpty {
            resolvedBundleId = bid
        } else if sourceApp == "SpotifyNative" || sourceApp == "Spotify" {
            resolvedBundleId = "com.spotify.client"
        } else if sourceApp == "MusicNative" || sourceApp == "Music" {
            resolvedBundleId = "com.apple.Music"
        } else if sourceApp.localizedCaseInsensitiveContains("Brave") {
            resolvedBundleId = "com.brave.Browser"
        } else if sourceApp.localizedCaseInsensitiveContains("Chrome") {
            resolvedBundleId = "com.google.Chrome"
        } else if sourceApp == "Arc" {
            resolvedBundleId = "company.thebrowser.Browser"
        } else if sourceApp.localizedCaseInsensitiveContains("Edge") {
            resolvedBundleId = "com.microsoft.edgemac"
        } else {
            resolvedBundleId = "com.apple.Safari"
        }
        
        if let cached = Self.artworkCache.object(forKey: resolvedBundleId as NSString) {
            self.artworkImage = cached
        } else if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: resolvedBundleId) {
            let img = NSWorkspace.shared.icon(forFile: appUrl.path)
            Self.artworkCache.setObject(img, forKey: resolvedBundleId as NSString)
            self.artworkImage = img
        }
    }
    
    private func fetchAndCacheImage(from urlString: String, cacheKey: String) {
        guard let url = URL(string: urlString) else { return }
        self.lastArtworkURL = urlString
        var request = URLRequest(url: url)
        request.timeoutInterval = 8.0
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self = self, let data = data, let img = NSImage(data: data) else { return }
            Self.artworkCache.setObject(img, forKey: cacheKey as NSString)
            Self.artworkCache.setObject(img, forKey: urlString as NSString)
            Task { @MainActor in
                if self.lastArtworkURL == urlString || self.artworkImage == nil {
                    self.artworkImage = img
                }
            }
        }.resume()
    }
    
    private func extractYouTubeVideoId(from url: String) -> String? {
        if let components = URLComponents(string: url), let queryItems = components.queryItems {
            if let vItem = queryItems.first(where: { $0.name == "v" }), let vVal = vItem.value, !vVal.isEmpty {
                return vVal
            }
        }
        if url.contains("/shorts/") {
            let parts = url.components(separatedBy: "/shorts/")
            if parts.count > 1 {
                let id = parts[1].components(separatedBy: "?")[0].components(separatedBy: "/")[0]
                if !id.isEmpty { return id }
            }
        }
        if url.contains("youtu.be/") {
            let parts = url.components(separatedBy: "youtu.be/")
            if parts.count > 1 {
                let id = parts[1].components(separatedBy: "?")[0].components(separatedBy: "/")[0]
                if !id.isEmpty { return id }
            }
        }
        return nil
    }
    
    private func fetchYouTubeThumbnailUrl() -> String? {
        let script = """
        tell application "System Events"
            set isBrave to exists (processes whose name is "Brave Browser")
            set isChrome to exists (processes whose name is "Google Chrome")
            set isSafari to exists (processes whose name is "Safari")
        end tell
        if isBrave then
            try
                tell application "Brave Browser"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                return tabURL
                            end if
                        end repeat
                    end repeat
                end tell
            end try
        end if
        if isChrome then
            try
                tell application "Google Chrome"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                return tabURL
                            end if
                        end repeat
                    end repeat
                end tell
            end try
        end if
        if isSafari then
            try
                tell application "Safari"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                return tabURL
                            end if
                        end repeat
                    end repeat
                end tell
            end try
        end if
        return "none"
        """
        if let urlStr = runIsolatedAppleScript(script), urlStr != "none" && !urlStr.isEmpty {
            if let videoId = extractYouTubeVideoId(from: urlStr) {
                return "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
            }
        }
        return nil
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
    
    // MARK: - Playback Controls
    func togglePlayPause() {
        Task { @MainActor in
            self.isPlaying.toggle()
        }
        runControlCommand("playpause")
    }
    
    func skipForward() {
        runControlCommand("next track")
    }
    
    func skipBackward() {
        runControlCommand("previous track")
    }
    
    func seek(to seconds: Double) {
        let clampedSeconds = max(0, duration > 0 ? min(seconds, duration) : seconds)
        let source = self.currentSource
        
        Task { @MainActor in
            self.currentTime = clampedSeconds
            self.seekLockUntil = Date().addingTimeInterval(2.0)
        }
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let runningApps = NSWorkspace.shared.runningApplications
            let isSpotifyAppRunning = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.spotify.client" }
            let isMusicAppRunning = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
            
            let isAppleMusicNative = (source == "MusicNative" || (source == "Music" && isMusicAppRunning)) && isMusicAppRunning
            let isSpotifyNative = (source == "SpotifyNative" || (source == "Spotify" && isSpotifyAppRunning)) && isSpotifyAppRunning
            
            if isAppleMusicNative {
                _ = NSAppleScript(source: "try\ntell application id \"com.apple.Music\" to set player position to \(clampedSeconds)\nend try")?.executeAndReturnError(nil)
                Self.mrSetElapsedTime?(clampedSeconds)
                let dict: [String: Any] = ["kMRMediaRemoteOptionPlaybackPosition": NSNumber(value: clampedSeconds)]
                _ = Self.mrSendCommand?(18, dict as CFDictionary)
            } else if isSpotifyNative {
                _ = NSAppleScript(source: "try\ntell application id \"com.spotify.client\" to set player position to \(clampedSeconds)\nend try")?.executeAndReturnError(nil)
                Self.mrSetElapsedTime?(clampedSeconds)
                let dict: [String: Any] = ["kMRMediaRemoteOptionPlaybackPosition": NSNumber(value: clampedSeconds)]
                _ = Self.mrSendCommand?(18, dict as CFDictionary)
            } else {
                Self.mrSetElapsedTime?(clampedSeconds)
                if let sendCmd = Self.mrSendCommand {
                    let dict: [String: Any] = ["kMRMediaRemoteOptionPlaybackPosition": NSNumber(value: clampedSeconds)]
                    _ = sendCmd(18, dict as CFDictionary)
                    _ = sendCmd(11, dict as CFDictionary)
                }
                self.seekInWebBrowsers(to: clampedSeconds)
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self = self else { return }
                if isAppleMusicNative {
                    let script = NSAppleScript(source: "try\ntell application id \"com.apple.Music\" to get player position\nend try")
                    var err: NSDictionary?
                    let desc = script?.executeAndReturnError(&err)
                    if let posStr = desc?.stringValue, let pos = Double(posStr) {
                        Task { @MainActor in
                            if Date() < self.seekLockUntil {
                                self.currentTime = pos
                            }
                        }
                    }
                } else {
                    self.fetchNowPlayingInfo()
                }
            }
        }
    }
    
    private func seekInWebBrowsers(to seconds: Double) {
        let jsSeek = """
        (function() {
            var targetSec = \(seconds);
            try {
                var yt = document.getElementById('movie_player') || document.querySelector('.html5-video-player');
                if (yt && typeof yt.seekTo === 'function') {
                    yt.seekTo(targetSec, true);
                }
            } catch(e) {}
            try {
                if (window.location.href.indexOf('netflix.com') !== -1 && window.netflix && window.netflix.appContext) {
                    var vp = window.netflix.appContext.state.playerApp.getAPI().videoPlayer;
                    if (vp) {
                        var sessionIds = vp.getAllPlayerSessionIds();
                        if (sessionIds && sessionIds.length > 0) {
                            var p = vp.getVideoPlayerBySessionId(sessionIds[sessionIds.length - 1]);
                            if (p && typeof p.seek === 'function') {
                                p.seek(targetSec * 1000);
                            }
                        }
                    }
                }
            } catch(e) {}
            try {
                if (window.location.href.indexOf('spotify.com') !== -1) {
                    var pb = document.querySelector('[data-testid="playback-progressbar"] input');
                    if (pb) {
                        var maxVal = Number(pb.max) || 1;
                        pb.value = Math.min(Math.max(0, targetSec * 1000), maxVal);
                        pb.dispatchEvent(new Event('input', { bubbles: true }));
                        pb.dispatchEvent(new Event('change', { bubbles: true }));
                    }
                }
            } catch(e) {}
            try {
                var mediaList = Array.from(document.querySelectorAll('video, audio'));
                var active = mediaList.find(function(m) { return !m.paused && !m.ended; }) || document.querySelector('.html5-main-video') || mediaList[0];
                if (active) {
                    active.currentTime = targetSec;
                }
                for (var i = 0; i < mediaList.length; i++) {
                    if (mediaList[i] !== active && !mediaList[i].paused) {
                        mediaList[i].currentTime = targetSec;
                    }
                }
            } catch(e) {}
        })();
        """
        
        let escapedJsSeek = jsSeek
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        let runningApps = NSWorkspace.shared.runningApplications
        let chromiumBrowsers: [(name: String, bundleSubstring: String)] = [
            ("Brave Browser", "brave"),
            ("Google Chrome", "Chrome"),
            ("Arc", "company.thebrowser.Browser"),
            ("Microsoft Edge", "edgemac"),
            ("Opera", "Opera"),
            ("Vivaldi", "Vivaldi")
        ]
        
        for (appName, bundleSubstring) in chromiumBrowsers {
            let isRunning = runningApps.contains { app in
                let bid = app.bundleIdentifier ?? ""
                let name = app.localizedName ?? ""
                return bid.localizedCaseInsensitiveContains(bundleSubstring) || name.localizedCaseInsensitiveContains(appName)
            }
            if isRunning {
                let script = """
                tell application "\(appName)"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "spotify.com" or tabURL contains "netflix.com" or tabURL contains "music.apple.com" or tabURL contains "soundcloud.com" or tabURL contains "twitch.tv" or tabURL contains "vimeo.com") then
                                try
                                    execute t javascript "\(escapedJsSeek)"
                                on error
                                end try
                            end if
                        end repeat
                    end repeat
                end tell
                """
                _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        }
        
        let isSafariRunning = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Safari" }
        if isSafariRunning {
            let script = """
            tell application "Safari"
                repeat with win in every window
                    repeat with t in every tab of win
                        set tabURL to URL of t
                        if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "spotify.com" or tabURL contains "netflix.com" or tabURL contains "music.apple.com" or tabURL contains "soundcloud.com" or tabURL contains "twitch.tv" or tabURL contains "vimeo.com") then
                            try
                                do JavaScript "\(escapedJsSeek)" in t
                            on error
                            end try
                        end if
                    end repeat
                end repeat
            end tell
            """
            _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
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
        let isYT = self.isYouTube
        let cur = self.currentTime
        let dur = self.duration
        let service = self.mediaService
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let runningApps = NSWorkspace.shared.runningApplications
            let isSpotifyAppRunning = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.spotify.client" }
            let isMusicAppRunning = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
            
            let isSpotifyNative = (source == "SpotifyNative" || (source == "Spotify" && isSpotifyAppRunning)) && isSpotifyAppRunning
            let isAppleMusicNative = (source == "MusicNative" || (source == "Music" && isMusicAppRunning)) && isMusicAppRunning
            
            if isSpotifyNative {
                _ = NSAppleScript(source: "try\ntell application id \"com.spotify.client\" to \(command)\nend try")?.executeAndReturnError(nil)
            } else if isAppleMusicNative {
                _ = NSAppleScript(source: "try\ntell application id \"com.apple.Music\" to \(command)\nend try")?.executeAndReturnError(nil)
            } else if isYT && command != "playpause" {
                if command == "next track", dur > 0 {
                    self.seek(to: min(dur, cur + 10))
                } else if command == "previous track" {
                    if cur > 3 {
                        self.seek(to: 0)
                    } else {
                        self.seek(to: max(0, cur - 10))
                    }
                }
            } else if service == .other && source == "MediaRemote" {
                let cmdCode: Int32
                if command == "playpause" { cmdCode = 2 }
                else if command == "next track" { cmdCode = 4 }
                else if command == "previous track" { cmdCode = 5 }
                else { cmdCode = 2 }
                _ = Self.mrSendCommand?(cmdCode, nil)
            } else {
                self.sendBrowserControlCommand(command)
            }
            
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.fetchNowPlayingInfo()
            }
        }
    }
    
    private func sendBrowserControlCommand(_ command: String) {
        let jsCmd = """
        (function() {
            var cmd = '\(command)';
            if (cmd === 'playpause') {
                var spPlayBtn = document.querySelector('button[data-testid="control-button-playpause"], [data-testid="control-button-playpause"], button[aria-label="Pause"], button[aria-label="Play"]');
                var nfPlayBtn = document.querySelector('[data-uia="control-play-pause-play"], [data-uia="control-play-pause-pause"], [data-uia="control-play-pause"], .button-nfVideosPlay, .button-nfVideosPause');
                var ytPlayBtn = document.querySelector('.ytp-play-button, .play-pause-button.ytmusic-player-bar, #play-pause-button, .web-chrome-playback-controls__play-pause-btn');
                if (spPlayBtn) {
                    spPlayBtn.click();
                } else if (nfPlayBtn) {
                    nfPlayBtn.click();
                } else if (ytPlayBtn) {
                    ytPlayBtn.click();
                } else {
                    var videos = Array.from(document.querySelectorAll('video, audio'));
                    var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                    if (v) {
                        if (v.paused) v.play(); else v.pause();
                    }
                }
            } else if (cmd === 'next track') {
                var spNextBtn = document.querySelector('[data-testid="control-button-skip-forward"], button[data-testid="control-button-skip-forward"], button[aria-label="Next"]');
                var nfForwardBtn = document.querySelector('[data-uia="control-fast-forward"], [data-uia="control-seek-forward"], [data-uia="control-skip-forward"], .button-nfVideosFastForward');
                var nextBtn = document.querySelector('.ytp-next-button, .next-button.ytmusic-player-bar, .web-chrome-playback-controls__forward-btn');
                if (spNextBtn) {
                    spNextBtn.click();
                } else if (nfForwardBtn) {
                    nfForwardBtn.click();
                } else if (nextBtn) {
                    nextBtn.click();
                } else {
                    var videos2 = Array.from(document.querySelectorAll('video, audio'));
                    var v2 = videos2.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos2[0];
                    if (v2 && isFinite(v2.duration) && v2.duration > 0) {
                        v2.currentTime = Math.min(v2.duration, v2.currentTime + 10);
                    }
                }
            } else if (cmd === 'previous track') {
                var spPrevBtn = document.querySelector('[data-testid="control-button-skip-back"], button[data-testid="control-button-skip-back"], button[aria-label="Previous"]');
                var nfRewindBtn = document.querySelector('[data-uia="control-seek-back"], [data-uia="control-fast-rewind"], [data-uia="control-skip-back"], .button-nfVideosRewind');
                var prevBtn = document.querySelector('.ytp-prev-button, .previous-button.ytmusic-player-bar, .web-chrome-playback-controls__backward-btn');
                if (spPrevBtn) {
                    spPrevBtn.click();
                } else if (nfRewindBtn) {
                    nfRewindBtn.click();
                } else if (prevBtn) {
                    prevBtn.click();
                } else {
                    var videos3 = Array.from(document.querySelectorAll('video, audio'));
                    var v3 = videos3.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos3[0];
                    if (v3) {
                        if (v3.currentTime > 3) {
                            v3.currentTime = 0;
                        } else {
                            v3.currentTime = Math.max(0, v3.currentTime - 10);
                        }
                    }
                }
            }
        })();
        """

        let escapedJsCmd = jsCmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let runningApps = NSWorkspace.shared.runningApplications
        let chromiumBrowsers: [(name: String, bundleSubstring: String)] = [
            ("Brave Browser", "brave"),
            ("Google Chrome", "Chrome"),
            ("Arc", "company.thebrowser.Browser"),
            ("Microsoft Edge", "edgemac"),
            ("Opera", "Opera"),
            ("Vivaldi", "Vivaldi")
        ]

        for (appName, bundleSubstring) in chromiumBrowsers {
            let isRunning = runningApps.contains { app in
                let bid = app.bundleIdentifier ?? ""
                let name = app.localizedName ?? ""
                return bid.localizedCaseInsensitiveContains(bundleSubstring) || name.localizedCaseInsensitiveContains(appName)
            }
            if isRunning {
                let script = """
                tell application "\(appName)"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "spotify.com" or tabURL contains "netflix.com" or tabURL contains "music.apple.com") then
                                try
                                    execute t javascript "\(escapedJsCmd)"
                                on error
                                end try
                            end if
                        end repeat
                    end repeat
                end tell
                """
                _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
            }
        }

        let isSafariRunning = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Safari" }
        if isSafariRunning {
            let script = """
            tell application "Safari"
                repeat with win in every window
                    repeat with t in every tab of win
                        set tabURL to URL of t
                        if tabURL is not missing value and (tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "spotify.com" or tabURL contains "netflix.com" or tabURL contains "music.apple.com") then
                            try
                                do JavaScript "\(escapedJsCmd)" in t
                            on error
                            end try
                        end if
                    end repeat
                end repeat
            end tell
            """
            _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
        }
    }
}
