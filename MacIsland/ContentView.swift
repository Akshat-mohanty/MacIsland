//
//  ContentView.swift
//  MacIsland
//
//  Created by Adrien Martin on 25/08/26.
//

import SwiftUI

struct ContentView: View {
    @State private var isExpanded = false
    @State private var window: NSWindow?
    @State private var mediaManager = MediaManager()
    @State private var isHoveringSlider = false
    @State private var isDraggingSlider = false
    @State private var dragSliderTime: Double = 0
    @AppStorage(AppDelegate.showsDockIconKey) private var showsDockIcon = false
    private let collapsedHeight: CGFloat = 31
    private let expandedHeight: CGFloat = 92
    
    var body: some View {
        ZStack(alignment: .top) {
            // Using a completely clear background so the window is transparent
            Color.clear
            
            // The Island Container
            Group {
                if isExpanded {
                    VStack(spacing: 6) {
                        // Top Row: Artwork + Track Details + Playback Buttons
                        HStack(alignment: .center, spacing: 10) {
                            if let artwork = mediaManager.artworkImage {
                                Image(nsImage: artwork)
                                    .resizable()
                                    .aspectRatio(contentMode: mediaManager.isYouTube ? .fit : .fill)
                                    .frame(width: mediaManager.isYouTube ? 32 : 38, height: mediaManager.isYouTube ? 32 : 38)
                                    .clipShape(RoundedRectangle(cornerRadius: mediaManager.isYouTube ? 4 : 8))
                                    .frame(width: 38, height: 38)
                            } else {
                                Text("🎵")
                                    .font(.system(size: 24))
                                    .frame(width: 38, height: 38)
                            }
                        
                            // Track Title and Artist
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mediaManager.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text(mediaManager.artist.isEmpty ? "Unknown Artist" : mediaManager.artist)
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            // Media Controls
                            HStack(spacing: 8) {
                                Button(action: { mediaManager.skipBackward() }) {
                                    Image(systemName: "backward.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { mediaManager.togglePlayPause() }) {
                                    Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 17))
                                        .foregroundColor(.white)
                                        .frame(width: 32, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                Button(action: { mediaManager.skipForward() }) {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white)
                                        .frame(width: 28, height: 28)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                        // Bottom Row: Scrubber / Slidebar (always displayed when duration > 0)
                        if mediaManager.duration > 0 {
                            HStack(spacing: 8) {
                                Text(MediaManager.formatTime(isDraggingSlider ? dragSliderTime : mediaManager.currentTime))
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .frame(width: 36, alignment: .leading)

                                GeometryReader { geometry in
                                    let totalWidth = geometry.size.width
                                    let current = isDraggingSlider ? dragSliderTime : mediaManager.currentTime
                                    let progress = min(max(current / max(mediaManager.duration, 1), 0), 1)
                                    let currentPos = totalWidth * CGFloat(progress)

                                    ZStack(alignment: .leading) {
                                        // Background track
                                        Capsule()
                                            .fill(Color.white.opacity(0.2))
                                            .frame(height: isHoveringSlider || isDraggingSlider ? 5 : 3.5)

                                        // Progress filled track
                                        Capsule()
                                            .fill(Color.white)
                                            .frame(width: max(currentPos, 0), height: isHoveringSlider || isDraggingSlider ? 5 : 3.5)

                                        // Thumb Knob
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 9, height: 9)
                                            .shadow(color: .black.opacity(0.5), radius: 2)
                                            .offset(x: max(0, min(currentPos - 4.5, totalWidth - 9)))
                                            .opacity(isHoveringSlider || isDraggingSlider ? 1 : 0)
                                    }
                                    .frame(height: 12)
                                    .contentShape(Rectangle())
                                    .onHover { hovering in
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            isHoveringSlider = hovering
                                        }
                                    }
                                    .gesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { value in
                                                mediaManager.isScrubbing = true
                                                isDraggingSlider = true
                                                let clampedX = max(0, min(value.location.x, totalWidth))
                                                let newFraction = Double(clampedX / totalWidth)
                                                dragSliderTime = newFraction * mediaManager.duration
                                            }
                                            .onEnded { value in
                                                let clampedX = max(0, min(value.location.x, totalWidth))
                                                let newFraction = Double(clampedX / totalWidth)
                                                let targetTime = newFraction * mediaManager.duration
                                                dragSliderTime = targetTime
                                                mediaManager.seek(to: targetTime)
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                                    mediaManager.isScrubbing = false
                                                    isDraggingSlider = false
                                                }
                                            }
                                    )
                                }
                                .frame(height: 12)

                                Text(MediaManager.formatTime(mediaManager.duration))
                                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                    .foregroundColor(.gray)
                                    .frame(width: 36, alignment: .trailing)
                            }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        }
                    }
                    .frame(width: 420, height: expandedHeight)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.95)),
                        removal: .opacity.combined(with: .scale(scale: 0.92))
                    ))
                } else {
                    // iOS Compact Dynamic Island Presentation
                    HStack(spacing: 0) {
                        // Compact Leading (Mini album artwork or music icon)
                        if let artwork = mediaManager.artworkImage {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 17, height: 17)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .padding(.leading, 12)
                        } else if mediaManager.isPlaying {
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.leading, 14)
                        }

                        Spacer()

                        // Compact Trailing (Equalizer Waveform)
                        if mediaManager.isPlaying {
                            CompactEqualizerView()
                                .padding(.trailing, 14)
                        }
                    }
                    .frame(width: 200, height: collapsedHeight)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.92)),
                        removal: .opacity.combined(with: .scale(scale: 0.92))
                    ))
                }
            }
            .frame(width: isExpanded ? 420 : 200, height: isExpanded ? expandedHeight : collapsedHeight)
            .background(Color.black)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: isExpanded ? 36 : 18, bottomTrailingRadius: isExpanded ? 36 : 18, topTrailingRadius: 0))
            // Clean, direct easing curve without lingering spring oscillation
            .animation(.easeInOut(duration: 0.22), value: isExpanded)
            .contentShape(Rectangle())
            .onHover { hovering in
                guard hovering else {
                    if !isDraggingSlider {
                        isExpanded = false
                    }
                    return
                }

                isExpanded = true
            }
            // Dynamic island depth shadow
            .shadow(color: Color.black.opacity(isExpanded ? 0.45 : 0.25), radius: isExpanded ? 16 : 6, x: 0, y: isExpanded ? 6 : 2)
            .contextMenu {
                Button {
                    showsDockIcon.toggle()
                    AppDelegate.setDockIconVisible(showsDockIcon)
                } label: {
                    Label(showsDockIcon ? "Hide Dock Icon" : "Show Dock Icon", systemImage: "dock.rectangle")
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit MacIsland", systemImage: "power")
                }
            }
        }
        // Container size
        .frame(width: 500, height: 200)
        .ignoresSafeArea()
        .background(
            WindowAccessor { window in
                self.window = window
                AppDelegate.configureWindow(window)
            }
        )
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindowAvailable: (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.configure(window, onWindowAvailable: onWindowAvailable)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.configure(window, onWindowAvailable: onWindowAvailable)
            }
        }
    }

    final class Coordinator {
        private weak var configuredWindow: NSWindow?

        func configure(_ window: NSWindow, onWindowAvailable: (NSWindow) -> Void) {
            guard configuredWindow !== window else {
                return
            }

            configuredWindow = window
            onWindowAvailable(window)
        }
    }
}

struct CompactEqualizerView: View {
    @State private var phase = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 0.2, green: 0.85, blue: 0.4))
                .frame(width: 2.2, height: phase ? 11 : 4)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 0.2, green: 0.85, blue: 0.4))
                .frame(width: 2.2, height: phase ? 5 : 12)
            RoundedRectangle(cornerRadius: 1)
                .fill(Color(red: 0.2, green: 0.85, blue: 0.4))
                .frame(width: 2.2, height: phase ? 13 : 6)
        }
        .frame(height: 14)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
    }
}

#Preview {
    ContentView()
}

