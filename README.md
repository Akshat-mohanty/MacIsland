# MacIsland

**MacIsland** brings an authentic Apple Dynamic Island experience to macOS. It sits seamlessly at the top of your screen, contouring around the MacBook notch or display bezel, providing real-time "Now Playing" media information, interactive scrubbing, and media controls without stealing window focus.

---

##  Features

- **Authentic Apple Notch Design**: Precise concave top ears and squircle curves matching the physical MacBook Pro display bezel.
- **System-Wide & Desktop Media Support**: Native detection and playback controls for **Apple Music** and **Spotify Desktop**.
- **Browser & PWA Web Detection**: Real-time track information and duration from **YouTube**, **YouTube Music**, **Spotify Web**, and installed standalone web apps on **Brave Browser**, **Google Chrome**, **Safari**, **Arc**, and **Microsoft Edge**.
- **Interactive Scrubber & Dynamic Island Controls**:
  - Live album art & YouTube video thumbnails.
  - Interactive scrubbing progress bar.
  - Play, Pause, Skip (+10s), and Rewind (-10s) controls.
- **Zero Window Focus Stealing**: Runs as an ultra-lightweight non-activating status bar overlay that will never interrupt your active apps.

---

##  Quick Start (Running from Source)

### Option 1: 1-Click Terminal Command *(Recommended)*

Open Terminal and run:

```bash
git clone https://github.com/Akshat-mohanty/MacIsland.git
cd MacIsland/MacIsland
./run.sh
```

`./run.sh` will automatically build the project and launch **MacIsland** in the background.

---

## ⚙️ Requirements & Permissions

- **macOS**: 13.0 (Ventura) or later.
- **For Browser / Web App Media (Brave / Chrome / Safari)**:
  - In **Brave / Chrome**: Go to **View** ➔ **Developer** ➔ Ensure **"Allow JavaScript from Apple Events"** is checked.
  - In **System Settings** ➔ **Privacy & Security** ➔ **Automation**: Ensure **MacIsland** has permission toggled **ON** for your browser and media apps.

---

## 🛠️ Controls & Context Menu

- **Hover**: Move your mouse over the notch to expand the full media controller and progress scrubber.
- **Mouse Exit**: Springs back to the compact notch instantly.
- **Right-Click on the Island**:
  - Toggle Dock Icon visibility (show/hide).
  - Quit MacIsland.

---

## 📄 License

Open-source under the [MIT License](LICENSE).
