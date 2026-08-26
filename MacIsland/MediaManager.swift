import Foundation
import AppKit
import Observation

@Observable
class MediaManager {
    var title: String = "Not Playing"
    var artist: String = ""
    var artworkImage: NSImage? = nil
    var isPlaying: Bool = false
    var isYouTube: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isScrubbing: Bool = false
    var currentSource: String = ""
    
    private var timer: Timer?
    private var lastArtworkURL: String = ""
    
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
        let scriptSource = """
        try
            if application id "com.spotify.client" is running then
                tell application id "com.spotify.client"
                    if player state is playing then
                        set trackName to (name of current track)
                        set trackArtist to (artist of current track)
                        set curPos to (player position)
                        set curDur to (duration of current track) / 1000
                        return "SpotifyNative|" & trackName & "|" & trackArtist & "|playing|none|" & curPos & "|" & curDur
                    end if
                end tell
            end if
        end try

        try
            if application id "com.apple.Music" is running then
                tell application id "com.apple.Music"
                    if player state is playing then
                        set trackName to (name of current track)
                        set trackArtist to (artist of current track)
                        set curPos to (player position)
                        set curDur to (duration of current track)
                        return "MusicNative|" & trackName & "|" & trackArtist & "|playing|none|" & curPos & "|" & curDur
                    end if
                end tell
            end if
        end try

        set webScraper to "
            (function() {
                var v = document.querySelector('video');
                var a = document.querySelector('audio');
                var media = v || a;
                var url = window.location.href;
                var track = '', artist = '', isPlaying = 'paused', imgUrl = '', curPos = 0, curDur = 0;

                if (url.includes('music.youtube.com')) {
                    var titleEl = document.querySelector('.title.ytmusic-player-bar');
                    track = titleEl ? titleEl.textContent.trim() : document.title.replace(/ - YouTube Music$/, '');
                    var artEl = document.querySelector('.ytmusic-player-bar .byline a, .ytmusic-player-bar .byline, .ytmusic-player-bar .subtitle');
                    artist = artEl ? artEl.textContent.trim() : 'YouTube Music';
                    var imgEl = document.querySelector('.ytmusic-player-bar .image, .ytmusic-player-bar img');
                    if (imgEl && imgEl.src) imgUrl = imgEl.src;
                } else if (url.includes('youtube.com') || url.includes('youtu.be')) {
                    var titleEl = document.querySelector('h1.ytd-watch-metadata yt-formatted-string, #title h1 yt-formatted-string, ytd-watch-flexy h1, .ytp-title-link, .title.ytd-video-primary-info-renderer');
                    track = titleEl ? titleEl.textContent.trim() : document.title.replace(/ - YouTube$/, '');
                    var artEl = document.querySelector('#owner ytd-channel-name yt-formatted-string, #upload-info ytd-channel-name yt-formatted-string, ytd-channel-name a, #channel-name a');
                    artist = artEl ? artEl.textContent.trim() : 'YouTube';
                } else if (url.includes('spotify.com')) {
                    var t = document.querySelector('[data-testid=\\"context-item-link\\"]');
                    var art = document.querySelector('[data-testid=\\"context-item-info-subtitles\\"]');
                    var pb = document.querySelector('[data-testid=\\"control-button-playpause\\"]');
                    var img = document.querySelector('img[data-testid=\\"cover-art-image\\"]') || document.querySelector('img[data-testid=\\"context-item-image\\"]');
                    if (t && art) {
                        track = t.innerText;
                        artist = art.innerText.replace(/[\\\\r\\\\n]+/g, ', ');
                        isPlaying = (pb && pb.getAttribute('aria-label') === 'Pause') ? 'playing' : 'paused';
                        imgUrl = img ? img.src : '';
                    }
                }

                if (media) {
                    if (!url.includes('spotify.com')) {
                        isPlaying = (!media.paused && !media.ended && media.readyState > 1) ? 'playing' : 'paused';
                    }
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
                        var metaImg = document.querySelector('link[rel=\\"image_src\\"], meta[property=\\"og:image\\"]');
                        imgUrl = metaImg ? (metaImg.href || metaImg.content) : '';
                    }
                }

                if (track) {
                    return track.trim() + '|' + artist.trim() + '|' + isPlaying + '|' + (imgUrl || 'none') + '|' + Math.round(curPos) + '|' + Math.round(curDur);
                }
                return 'null';
            })();
        "

        -- 1. Check actively playing browser tabs first
        try
            if application "Brave Browser" is running then
                tell application "Brave Browser"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" and res contains "|playing|" then
                                    return "Brave|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end try

        try
            if application "Google Chrome" is running then
                tell application "Google Chrome"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" and res contains "|playing|" then
                                    return "Chrome|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end try

        try
            if application "Arc" is running then
                tell application "Arc"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" and res contains "|playing|" then
                                    return "Arc|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end try

        try
            if application "Safari" is running then
                tell application id "com.apple.Safari"
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
            end if
        end try

        -- 2. Check paused native apps
        try
            if application id "com.spotify.client" is running then
                tell application id "com.spotify.client"
                    set trackName to (name of current track)
                    set trackArtist to (artist of current track)
                    set curPos to (player position)
                    set curDur to (duration of current track) / 1000
                    return "SpotifyNative|" & trackName & "|" & trackArtist & "|paused|none|" & curPos & "|" & curDur
                end tell
            end if
        end try

        try
            if application id "com.apple.Music" is running then
                tell application id "com.apple.Music"
                    set trackName to (name of current track)
                    set trackArtist to (artist of current track)
                    set curPos to (player position)
                    set curDur to (duration of current track)
                    return "MusicNative|" & trackName & "|" & trackArtist & "|paused|none|" & curPos & "|" & curDur
                end tell
            end if
        end try

        -- 3. Check paused browser tabs
        try
            if application "Brave Browser" is running then
                tell application "Brave Browser"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" then
                                    return "Brave|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end try

        try
            if application "Google Chrome" is running then
                tell application "Google Chrome"
                    repeat with win in every window
                        repeat with t in every tab of win
                            set tabURL to URL of t
                            if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                set res to execute t javascript webScraper
                                if res is not missing value and res is not "null" then
                                    return "Chrome|" & res
                                end if
                            end if
                        end repeat
                    end repeat
                end tell
            end if
        end try

        try
            if application "Safari" is running then
                tell application id "com.apple.Safari"
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
            end if
        end try

        return ""
        """
        
        executeScriptAndParse(scriptSource)
    }
    
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
                
                if imgUrlString != "none" && !imgUrlString.isEmpty, let url = URL(string: imgUrlString) {
                    if self.lastArtworkURL == imgUrlString && self.artworkImage != nil {
                        Task { @MainActor in
                            self.currentSource = sourceApp
                            self.title = newTitle
                            self.artist = newArtist
                            self.isPlaying = newIsPlaying
                            self.isYouTube = newIsYouTube
                            if !self.isScrubbing {
                                self.currentTime = newCurPos
                            }
                            self.duration = newDuration
                        }
                    } else {
                        // Fetch artwork asynchronously
                        Task {
                            if let data = try? Data(contentsOf: url), let image = NSImage(data: data) {
                                await MainActor.run {
                                    self.lastArtworkURL = imgUrlString
                                    self.currentSource = sourceApp
                                    self.title = newTitle
                                    self.artist = newArtist
                                    self.isPlaying = newIsPlaying
                                    self.isYouTube = newIsYouTube
                                    if !self.isScrubbing {
                                        self.currentTime = newCurPos
                                    }
                                    self.duration = newDuration
                                    self.artworkImage = image
                                }
                            } else {
                                await MainActor.run {
                                    self.currentSource = sourceApp
                                    self.title = newTitle
                                    self.artist = newArtist
                                    self.isPlaying = newIsPlaying
                                    self.isYouTube = newIsYouTube
                                    if !self.isScrubbing {
                                        self.currentTime = newCurPos
                                    }
                                    self.duration = newDuration
                                }
                            }
                        }
                    }
                } else {
                    // Fallback to app icon
                    let bundleId: String
                    if sourceApp == "SpotifyNative" { bundleId = "com.spotify.client" }
                    else if sourceApp == "MusicNative" { bundleId = "com.apple.Music" }
                    else if sourceApp == "Brave" { bundleId = "com.brave.Browser" }
                    else if sourceApp == "Chrome" { bundleId = "com.google.Chrome" }
                    else if sourceApp == "Arc" { bundleId = "company.thebrowser.Browser" }
                    else { bundleId = "com.apple.Safari" }
                    
                    var newArtworkImage: NSImage? = nil
                    if let appUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                        newArtworkImage = NSWorkspace.shared.icon(forFile: appUrl.path)
                    }
                    
                    Task { @MainActor in
                        self.lastArtworkURL = ""
                        self.currentSource = sourceApp
                        self.title = newTitle
                        self.artist = newArtist
                        self.isPlaying = newIsPlaying
                        self.isYouTube = newIsYouTube
                        if !self.isScrubbing {
                            self.currentTime = newCurPos
                        }
                        self.duration = newDuration
                        self.artworkImage = newArtworkImage
                    }
                }
            } else {
                setNotPlaying()
            }
        } else {
            setNotPlaying()
        }
    }
    
    private func setNotPlaying() {
        Task { @MainActor in
            self.lastArtworkURL = ""
            self.currentSource = ""
            self.title = "Not Playing"
            self.artist = ""
            self.isPlaying = false
            self.artworkImage = nil
            self.isYouTube = false
            self.currentTime = 0
            self.duration = 0
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
        let source = self.currentSource
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var scriptSource = ""

            if source == "SpotifyNative" {
                scriptSource = """
                try
                    tell application id "com.spotify.client" to set player position to \(seconds)
                end try
                """
            } else if source == "MusicNative" {
                scriptSource = """
                try
                    tell application id "com.apple.Music" to set player position to \(seconds)
                end try
                """
            } else {
                let jsSeek = "(function() { var m = document.querySelector('video, audio'); if (m) { m.currentTime = \(seconds); } })();"
                
                let browsers = ["Brave Browser", "Google Chrome", "Arc"]
                for b in browsers {
                    scriptSource += """
                    try
                        tell application "\(b)"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                        execute t javascript "\(jsSeek)"
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    """
                }
                
                scriptSource += """
                try
                    tell application id "com.apple.Safari"
                        repeat with win in every window
                            repeat with t in every tab of win
                                set tabURL to URL of t
                                if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                    do JavaScript "\(jsSeek)" in t
                                end if
                            end repeat
                        end tell
                    end try
                end try
                """
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
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var scriptSource = ""

            if source == "SpotifyNative" {
                scriptSource = """
                try
                    tell application id "com.spotify.client" to \(command)
                end try
                """
            } else if source == "MusicNative" {
                scriptSource = """
                try
                    tell application id "com.apple.Music" to \(command)
                end try
                """
            } else {
                let jsCmd = """
                (function() {
                    var cmd = '\(command)';
                    var v = document.querySelector('video');
                    var a = document.querySelector('audio');
                    var media = v || a;
                    
                    if (cmd === 'playpause') {
                        if (media) {
                            if (media.paused) {
                                media.play();
                            } else {
                                media.pause();
                            }
                        } else {
                            var playBtn = document.querySelector('.ytp-play-button, .play-pause-button.ytmusic-player-bar, #play-pause-button, [data-testid=\"control-button-playpause\"]');
                            if (playBtn) playBtn.click();
                        }
                    } else if (cmd === 'next track') {
                        var nextBtn = document.querySelector('.ytp-next-button, .next-button.ytmusic-player-bar, [data-testid=\"control-button-skip-forward\"]');
                        if (nextBtn) {
                            nextBtn.click();
                        } else if (media && isFinite(media.duration)) {
                            media.currentTime = Math.min(media.duration, media.currentTime + 10);
                        }
                    } else if (cmd === 'previous track') {
                        var prevBtn = document.querySelector('.ytp-prev-button, .previous-button.ytmusic-player-bar, [data-testid=\"control-button-skip-back\"]');
                        if (prevBtn) {
                            prevBtn.click();
                        } else if (media) {
                            if (media.currentTime > 3) {
                                media.currentTime = 0;
                            } else {
                                media.currentTime = Math.max(0, media.currentTime - 10);
                            }
                        }
                    }
                })();
                """
                
                let browsers = ["Brave Browser", "Google Chrome", "Arc"]
                for b in browsers {
                    scriptSource += """
                    try
                        tell application "\(b)"
                            repeat with win in every window
                                repeat with t in every tab of win
                                    set tabURL to URL of t
                                    if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                        execute t javascript "\(jsCmd)"
                                    end if
                                end repeat
                            end repeat
                        end tell
                    end try
                    """
                }
                
                scriptSource += """
                try
                    tell application id "com.apple.Safari"
                        repeat with win in every window
                            repeat with t in every tab of win
                                set tabURL to URL of t
                                if tabURL is not missing value and (tabURL contains "spotify.com" or tabURL contains "youtube.com" or tabURL contains "youtu.be") then
                                    do JavaScript "\(jsCmd)" in t
                                end if
                            end repeat
                        end tell
                    end try
                end try
                """
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