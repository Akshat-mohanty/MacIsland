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
            return Color(red: 255/255.0, green: 51/255.0, blue: 51/255.0) // YouTube Red #FF3333
        case .appleMusic:
            return Color(red: 250/255.0, green: 45/255.0, blue: 72/255.0) // Apple Music Pink-Red
        case .netflix:
            return Color(red: 229/255.0, green: 9/255.0, blue: 20/255.0) // Netflix Red
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
    
    // MARK: - MediaRemote Private Framework Dynamically Loaded Symbols
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
        // 1. Check MediaRemote asynchronously
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
                           self.parseMediaRemoteInfo(
                               d,
                               clientBundleId: clientBundleId,
                               clientDisplayName: clientDisplayName,
                               clientPID: clientPID
                           ) {
                            return
                        }
                        self.checkFallbacks()
                    }
                }
            } else {
                getInfo(DispatchQueue.global(qos: .userInitiated)) { [weak self] dict in
                    guard let self = self else { return }
                    if let d = dict as? [String: Any],
                       self.parseMediaRemoteInfo(
                           d,
                           clientBundleId: "",
                           clientDisplayName: "",
                           clientPID: 0
                       ) {
                        return
                    }
                    self.checkFallbacks()
                }
            }
        } else {
            checkFallbacks()
        }
    }
    
    private func checkFallbacks() {
        let runningApps = NSWorkspace.shared.runningApplications
        
        // Native Spotify
        let hasSpotify = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.spotify.client" }
        if hasSpotify {
            let src = """
            try
                tell application id "com.spotify.client"
                    set pState to (player state as string)
                    set trackName to (name of current track as text)
                    set trackArtist to (artist of current track as text)
                    set curPos to (player position)
                    set curDur to (duration of current track) / 1000
                    set trackArt to "none"
                    try
                        set trackArt to (artwork url of current track as text)
                    end try
                    return "SpotifyNative|" & trackName & "|" & trackArtist & "|" & pState & "|" & trackArt & "|" & curPos & "|" & curDur & "|spotify"
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src), res.contains("|playing|") {
                executeScriptAndParse(res)
                return
            }
        }

        // Native Apple Music
        let hasMusic = runningApps.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        if hasMusic {
            let src = """
            try
                tell application id "com.apple.Music"
                    set pState to (player state as string)
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
                    return "MusicNative|" & trackName & "|" & trackArtist & "|" & pState & "|none|" & curPos & "|" & curDur & "|applemusic"
                end tell
            end try
            """
            if let res = runIsolatedAppleScript(src), res.contains("|playing|") {
                executeScriptAndParse(res)
                return
            }
        }

        // Browser scrapers
        let hasBrave = runningApps.contains { app in
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return bid.localizedCaseInsensitiveContains("brave") || name.localizedCaseInsensitiveContains("brave") || bid.localizedCaseInsensitiveContains("agimnkijcaahngcdmfeangaknmldooml")
        }
        let hasChrome = runningApps.contains { app in
            let bid = app.bundleIdentifier ?? ""
            let name = app.localizedName ?? ""
            return bid.localizedCaseInsensitiveContains("chrome") || name.localizedCaseInsensitiveContains("chrome")
        }
        let hasArc = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("thebrowser") }
        let hasSafari = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("safari") }
        let hasEdge = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("edge") }

        let chromiumBrowsers = [
            ("Brave Browser", hasBrave, "Brave"),
            ("Google Chrome", hasChrome, "Chrome"),
            ("Arc", hasArc, "Arc"),
            ("Microsoft Edge", hasEdge, "Edge")
        ]

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
                var t = document.querySelector('[data-testid="context-item-link"], [data-testid="now-playing-widget"] [data-testid="context-item-link"], a[data-testid="context-item-info-title"]');
                var art = document.querySelector('[data-testid="context-item-info-subtitles"], [data-testid="now-playing-widget"] [data-testid="context-item-info-subtitles"], [data-testid="context-item-info-artist"]');
                var pb = document.querySelector('[data-testid="control-button-playpause"], button[data-testid="control-button-playpause"], button[aria-label="Pause"], button[aria-label="Play"]');
                var img = document.querySelector('img[data-testid="cover-art-image"]') || document.querySelector('img[data-testid="context-item-image"]') || document.querySelector('[data-testid="now-playing-widget"] img');
                if (t && (t.innerText || t.textContent)) {
                    track = (t.innerText || t.textContent).trim();
                    if (art) {
                        artist = (art.innerText || art.textContent || '').replace(/[\\r\\n]+/g, ', ').trim();
                    }
                    if (pb) {
                        var label = pb.getAttribute('aria-label') || '';
                        isPlaying = (label.toLowerCase().indexOf('pause') !== -1) ? 'playing' : 'paused';
                    } else if (v) {
                        isPlaying = (!v.paused && !v.ended) ? 'playing' : 'paused';
                    }
                    imgUrl = img ? img.src : '';
                }
                
                function parseTimeStr(s) {
                    var p = (s || '').trim().split(':').map(Number);
                    if (p.length === 2) return p[0]*60 + p[1];
                    if (p.length === 3) return p[0]*3600 + p[1]*60 + p[2];
                    return 0;
                }
                var curEl = document.querySelector('[data-testid="playback-position"]');
                var durEl = document.querySelector('[data-testid="playback-duration"]');
                if (curEl && durEl && curEl.textContent && durEl.textContent) {
                    curPos = parseTimeStr(curEl.textContent);
                    curDur = parseTimeStr(durEl.textContent);
                }
                if (!curPos && !curDur) {
                    var inp = document.querySelector('[data-testid="playback-progressbar"] input');
                    if (inp) {
                        curPos = Math.round(Number(inp.value) / 1000);
                        curDur = Math.round(Number(inp.max) / 1000);
                    }
                }
            } else if (url.includes('music.apple.com')) {
                var titleEl = document.querySelector('.web-chrome-playback-lcd__sub-copy-scroll-inner-text-wrapper, [data-testid="lcd-song-title"], .lcd-label__primary');
                track = titleEl ? (titleEl.textContent || titleEl.innerText).trim() : document.title.replace(/ - Apple Music$/, '');
                var artEl = document.querySelector('.web-chrome-playback-lcd__sub-copy-scroll-inner-text-wrapper a, [data-testid="lcd-artist-name"], .lcd-label__secondary');
                artist = artEl ? (artEl.textContent || artEl.innerText).trim() : 'Apple Music';
                var imgEl = document.querySelector('.web-chrome-playback-lcd__artwork img, [data-testid="lcd-artwork"] img, .media-artwork-v2 img, [data-testid="artwork-component"] img');
                if (imgEl && imgEl.src) imgUrl = imgEl.src;
                if (!imgUrl) {
                    var srcEl = document.querySelector('.web-chrome-playback-lcd__artwork source, [data-testid="lcd-artwork"] source');
                    if (srcEl && srcEl.srcset) {
                        var parts = srcEl.srcset.split(',');
                        imgUrl = parts[parts.length - 1].trim().split(' ')[0];
                    }
                }
                var pb = document.querySelector('.web-chrome-playback-controls__play-pause-btn, [data-testid="play-pause-button"]');
                isPlaying = (v && !v.paused && !v.ended) ? 'playing' : (pb && pb.getAttribute('aria-label') === 'Pause' ? 'playing' : 'paused');
            } else if (url.includes('netflix.com')) {
                var titleEl = document.querySelector('[data-uia="video-title"], .video-title, [data-uia="watch-video-title"], .ellipsize-js');
                var showName = '';
                var episodeName = '';
                if (titleEl) {
                    var h4 = titleEl.querySelector('h4');
                    var spans = Array.from(titleEl.querySelectorAll('span')).map(function(s) { return (s.textContent || s.innerText || '').trim(); }).filter(Boolean);
                    if (h4) {
                        showName = (h4.textContent || h4.innerText || '').trim();
                        if (spans.length > 0) episodeName = spans.join(' - ');
                    } else if (spans.length > 0) {
                        showName = spans[0];
                        if (spans.length > 1) episodeName = spans.slice(1).join(' - ');
                    } else {
                        showName = (titleEl.textContent || titleEl.innerText || '').trim();
                    }
                }
                if (!showName && document.title) showName = document.title.trim();
                showName = showName.replace(/^Watch\\s+/i, '').replace(/\\s*[\\|\\-–—]\\s*Netflix.*$/i, '').trim();
                track = showName || 'Netflix';
                artist = episodeName || 'Netflix';
                if (v) isPlaying = (!v.paused && !v.ended) ? 'playing' : 'paused';
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
                }
            }

            var service = 'other';
            if (url.includes('youtube.com') || url.includes('youtu.be') || url.includes('music.youtube.com')) service = 'youtube';
            else if (url.includes('spotify.com')) service = 'spotify';
            else if (url.includes('netflix.com')) service = 'netflix';
            else if (url.includes('music.apple.com')) service = 'applemusic';

            if (track) {
                return track.trim() + '|' + artist.trim() + '|' + isPlaying + '|' + (imgUrl || 'none') + '|' + Math.round(curPos) + '|' + Math.round(curDur) + '|' + service;
            }
            return 'null';
        })();
        """

        let escapedScraper = rawScraper
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        for (appName, isRunning, tag) in chromiumBrowsers where isRunning {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "\(appName)"
                    set fallbackCandidate to "null"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com" or tabURL contains "music.apple.com") then
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

        if hasSafari {
            let src = """
            set webScraper to "\(escapedScraper)"
            try
                tell application "Safari"
                    set fallbackCandidate to "null"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be" or tabURL contains "netflix.com" or tabURL contains "music.apple.com") then
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

        setNotPlaying()
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
        
        // Comprehensive service identification
        let isYouTube = clientDisplayName.localizedCaseInsensitiveContains("YouTube") ||
                        appName.localizedCaseInsensitiveContains("YouTube") ||
                        fullBundleId.localizedCaseInsensitiveContains("youtube") ||
                        fullBundleId.localizedCaseInsensitiveContains("agimnkijcaahngcdmfeangaknmldooml") ||
                        fullBundleId.localizedCaseInsensitiveContains("cinhimbnkkaohjvfdleckmgagpcbmegf") ||
                        title.localizedCaseInsensitiveContains("YouTube") ||
                        artist.localizedCaseInsensitiveContains("YouTube") ||
                        rawAlbum.localizedCaseInsensitiveContains("YouTube")
        
        let isNetflix = clientDisplayName.localizedCaseInsensitiveContains("Netflix") ||
                        appName.localizedCaseInsensitiveContains("Netflix") ||
                        fullBundleId.localizedCaseInsensitiveContains("netflix") ||
                        title.localizedCaseInsensitiveContains("Netflix") ||
                        artist.localizedCaseInsensitiveContains("Netflix") ||
                        rawAlbum.localizedCaseInsensitiveContains("Netflix")
        
        let isSpotify = clientDisplayName.localizedCaseInsensitiveContains("Spotify") ||
                        appName.localizedCaseInsensitiveContains("Spotify") ||
                        fullBundleId.localizedCaseInsensitiveContains("spotify") ||
                        fullBundleId.localizedCaseInsensitiveContains("pjibgflleapemflmbggkgajjjonlganj") ||
                        title.localizedCaseInsensitiveContains("Spotify") ||
                        artist.localizedCaseInsensitiveContains("Spotify")
        
        let isAppleMusic = clientDisplayName.localizedCaseInsensitiveContains("Music") ||
                           appName == "Music" ||
                           fullBundleId == "com.apple.Music"
        
        if isYouTube {
            service = .youtube
            title = title
                .replacingOccurrences(of: " - YouTube", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: " - YouTube Music", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if artist.isEmpty || artist == appName {
                artist = rawAlbum.isEmpty ? "YouTube" : rawAlbum
            }
        } else if isNetflix {
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
        } else if isSpotify {
            service = .spotify
        } else if isAppleMusic {
            service = .appleMusic
        } else {
            service = .other
        }
        
        // Artwork extraction
        var artwork: NSImage? = nil
        if let artData = d["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data, let img = NSImage(data: artData) {
            artwork = img
        }
        
        var finalDuration = duration
        let timeSince = Date().timeIntervalSince(timestamp)
        let calculatedPos = max(0, isPlayingBool ? (elapsed + timeSince * (rateVal > 0 ? rateVal : 1.0)) : elapsed)
        let finalPos = duration > 0 ? min(calculatedPos, duration) : calculatedPos
        
        let isNativeMusicRunning = NSWorkspace.shared.runningApplications.contains { ($0.bundleIdentifier ?? "") == "com.apple.Music" }
        if (isAppleMusic || service == .appleMusic || appName == "Music" || fullBundleId == "com.apple.Music") && isNativeMusicRunning {
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
            } else {
                self.loadAppIcon(for: self.currentSource, bundleId: fullBundleId)
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
                let titleChanged = (self.title != newTitle)
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
                    if let appleMusicArt = self.getOrFetchAppleMusicArtwork(for: newTitle, artist: newArtist) {
                        self.artworkImage = appleMusicArt
                    } else {
                        self.lastArtworkURL = ""
                        self.loadAppIcon(for: sourceApp)
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
        } else if sourceApp == "Brave" || sourceApp.contains("Brave") {
            resolvedBundleId = "com.brave.Browser"
        } else if sourceApp == "Chrome" || sourceApp.contains("Chrome") {
            resolvedBundleId = "com.google.Chrome"
        } else if sourceApp == "Arc" {
            resolvedBundleId = "company.thebrowser.Browser"
        } else if sourceApp == "Edge" || sourceApp.contains("Edge") {
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
                // Universal MediaRemote seek for web/other
                Self.mrSetElapsedTime?(clampedSeconds)
                if let sendCmd = Self.mrSendCommand {
                    let dict: [String: Any] = ["kMRMediaRemoteOptionPlaybackPosition": NSNumber(value: clampedSeconds)]
                    _ = sendCmd(18, dict as CFDictionary)
                    _ = sendCmd(11, dict as CFDictionary)
                }
                // Web browsers seek (YouTube, YouTube Music, Netflix, Spotify Web, HTML5 Video/Audio)
                self.seekInWebBrowsers(to: clampedSeconds)
            }
            
            // Delay then sync position from Music.app (for Apple Music) or MediaRemote
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
        
        let isSafariRunning = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("Safari") }
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
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Universal MediaRemote control
            let cmdCode: Int32
            if command == "playpause" { cmdCode = 2 }
            else if command == "next track" { cmdCode = 4 }
            else if command == "previous track" { cmdCode = 5 }
            else { cmdCode = 2 }
            _ = Self.mrSendCommand?(cmdCode, nil)
            
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
                // If skipping video on YouTube, seek forward/back 10 seconds
                if command == "next track", dur > 0 {
                    self.seek(to: min(dur, cur + 10))
                } else if command == "previous track" {
                    if cur > 3 {
                        self.seek(to: 0)
                    } else {
                        self.seek(to: max(0, cur - 10))
                    }
                }
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
                var spPlayBtn = document.querySelector('[data-testid="control-button-playpause"], button[data-testid="control-button-playpause"], button[aria-label="Pause"], button[aria-label="Play"], [data-testid="play-button"], button[data-testid="play-button"]');
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
                var nextBtn = document.querySelector('.ytp-next-button, .next-button.ytmusic-player-bar, [data-testid="control-button-skip-forward"], .web-chrome-playback-controls__forward-btn');
                if (spNextBtn) {
                    spNextBtn.click();
                } else if (nfForwardBtn) {
                    nfForwardBtn.click();
                } else if (nextBtn) {
                    nextBtn.click();
                } else {
                    var videos = Array.from(document.querySelectorAll('video, audio'));
                    var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                    if (v && isFinite(v.duration) && v.duration > 0) {
                        v.currentTime = Math.min(v.duration, v.currentTime + 10);
                    }
                }
            } else if (cmd === 'previous track') {
                var spPrevBtn = document.querySelector('[data-testid="control-button-skip-back"], button[data-testid="control-button-skip-back"], button[aria-label="Previous"]');
                var nfRewindBtn = document.querySelector('[data-uia="control-seek-back"], [data-uia="control-fast-rewind"], [data-uia="control-skip-back"], .button-nfVideosRewind');
                var prevBtn = document.querySelector('.ytp-prev-button, .previous-button.ytmusic-player-bar, [data-testid="control-button-skip-back"], .web-chrome-playback-controls__backward-btn');
                if (spPrevBtn) {
                    spPrevBtn.click();
                } else if (nfRewindBtn) {
                    nfRewindBtn.click();
                } else if (prevBtn) {
                    prevBtn.click();
                } else {
                    var videos = Array.from(document.querySelectorAll('video, audio'));
                    var v = videos.find(function(x) { return !x.paused; }) || document.querySelector('.html5-main-video') || videos[0];
                    if (v) {
                        if (v.currentTime > 3) {
                            v.currentTime = 0;
                        } else {
                            v.currentTime = Math.max(0, v.currentTime - 10);
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

        let isSafariRunning = runningApps.contains { ($0.bundleIdentifier ?? "").localizedCaseInsensitiveContains("Safari") }
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