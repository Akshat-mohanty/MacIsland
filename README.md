# MacIsland

MacIsland brings the iOS Dynamic Island experience to your Mac! It sits elegantly at the top of your screen, providing real-time "Now Playing" media information and interactive playback controls without interrupting your workflow.

## Features

- **System-Wide Media Detection:** Natively detects and controls playback for Apple Music and the Spotify Desktop app.
- **Advanced Web Scraper:** Intelligently finds media playing in background browser tabs.
  - Supports **Safari** and **Brave Browser** (including installed PWAs).
  - Perfect extraction of track names and artist metadata from **Spotify Web** and **YouTube**.
- **Live Album Art:** Scrapes and displays the actual high-res album artwork or video thumbnails directly in the Dynamic Island.
- **Universal Controls:** Interactive Play, Pause, Skip Forward, and Skip Backward buttons right on the island.
- **True Background Agent:** Runs completely silently in the background. It will never steal your focus or clutter your Dock.

## Requirements

- macOS 13.0 or later
- **Safari / Brave Browser:** For web media detection, you must enable "Allow JavaScript from Apple Events" in the browser's Developer menu.

## Setup & Installation

1. Open `MacIsland.xcodeproj` in Xcode.
2. Build and run the project.
3. (Optional) If prompted, grant MacIsland accessibility or automation permissions to control Spotify and your web browsers.

## How It Works

MacIsland uses a pure AppKit background lifecycle to remain invisible to the app switcher. For media detection, it bypasses restrictive private APIs by utilizing AppleScript and targeted JavaScript DOM injection to read and control media players flawlessly.

## License

This project is open-source and available under the MIT License.
