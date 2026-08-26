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
    @StateObject private var mediaManager = MediaManager()
    @State private var isHoveringSlider = false
    @State private var isDraggingSlider = false
    @State private var dragSliderTime: Double = 0
    @AppStorage(AppDelegate.showsDockIconKey) private var showsDockIcon = false
    @State private var collapseWorkItem: DispatchWorkItem?
    private let collapsedWidth: CGFloat = 210
    private let collapsedHeight: CGFloat = 32
    private let expandedWidth: CGFloat = 430
    private let expandedHeight: CGFloat = 96
    private let springAnimation: Animation = .spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)
    
    var body: some View {
        ZStack(alignment: .top) {
            // Transparent window base
            Color.clear
            
            // The Island Container
            ZStack {
                // Expanded View
                VStack(spacing: 7) {
                    // Top Row: Artwork + Track Details + Playback Controls
                    HStack(alignment: .center, spacing: 12) {
                        if let artwork = mediaManager.artworkImage {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: mediaManager.isYouTube ? .fit : .fill)
                                .frame(width: mediaManager.isYouTube ? 36 : 42, height: mediaManager.isYouTube ? 36 : 42)
                                .clipShape(RoundedRectangle(cornerRadius: mediaManager.isYouTube ? 5 : 8))
                                .shadow(color: .white.opacity(0.12), radius: 3)
                                .frame(width: 42, height: 42)
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(white: 0.15))
                                Image(systemName: "music.note")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            .frame(width: 42, height: 42)
                        }
                    
                        // Track Title and Artist
                        VStack(alignment: .leading, spacing: 2.5) {
                            Text(mediaManager.title)
                                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Text(mediaManager.artist.isEmpty ? "Unknown Artist" : mediaManager.artist)
                                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                                .foregroundColor(Color(white: 0.65))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Media Controls
                        HStack(spacing: 6) {
                            Button(action: { mediaManager.skipBackward() }) {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: { mediaManager.togglePlayPause() }) {
                                Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 32, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            Button(action: { mediaManager.skipForward() }) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.9))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 9)

                    // Bottom Row: Scrubber / Progress Bar
                    if mediaManager.duration > 0 {
                        HStack(spacing: 8) {
                            Text(MediaManager.formatTime(isDraggingSlider ? dragSliderTime : mediaManager.currentTime))
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundColor(Color(white: 0.55))
                                .frame(width: 34, alignment: .leading)

                            GeometryReader { geometry in
                                let totalWidth = geometry.size.width
                                let current = isDraggingSlider ? dragSliderTime : mediaManager.currentTime
                                let progress = min(max(current / max(mediaManager.duration, 1), 0), 1)
                                let currentPos = totalWidth * CGFloat(progress)

                                ZStack(alignment: .leading) {
                                    // Background track
                                    Capsule()
                                        .fill(Color.white.opacity(0.22))
                                        .frame(height: isHoveringSlider || isDraggingSlider ? 5 : 3.5)

                                    // Progress filled track
                                    Capsule()
                                        .fill(Color.white)
                                        .frame(width: max(currentPos, 0), height: isHoveringSlider || isDraggingSlider ? 5 : 3.5)

                                    // Thumb Knob
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 9, height: 9)
                                        .shadow(color: .black.opacity(0.45), radius: 2)
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
                                .foregroundColor(Color(white: 0.55))
                                .frame(width: 34, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 7)
                    }
                }
                .frame(width: expandedWidth, height: expandedHeight)
                .opacity(isExpanded ? 1 : 0)
                .allowsHitTesting(isExpanded)

                // Compact Notch View
                HStack(spacing: 0) {
                    // Leading Artwork / Music Icon
                    if let artwork = mediaManager.artworkImage {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4.5))
                            .padding(.leading, 12)
                    } else if mediaManager.title != "Not Playing" || mediaManager.isPlaying {
                        Image(systemName: "music.note")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.leading, 13)
                    }

                    Spacer()

                    // Trailing Animated Audio Spectrum or Paused Indicator
                    if mediaManager.isPlaying {
                        AudioSpectrumView()
                            .padding(.trailing, 12)
                    } else if mediaManager.title != "Not Playing" {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.trailing, 13)
                    }
                }
                .frame(width: collapsedWidth, height: collapsedHeight)
                .opacity(isExpanded ? 0 : 1)
                .allowsHitTesting(!isExpanded)
            }
            .frame(width: isExpanded ? expandedWidth : collapsedWidth, height: isExpanded ? expandedHeight : collapsedHeight)
            .background(
                NotchShape(
                    topRadius: isExpanded ? 5.5 : 4.0,
                    bottomRadius: isExpanded ? 22.0 : 12.0
                )
                .fill(Color.black)
            )
            .clipShape(
                NotchShape(
                    topRadius: isExpanded ? 5.5 : 4.0,
                    bottomRadius: isExpanded ? 22.0 : 12.0
                )
            )
            .contentShape(
                NotchShape(
                    topRadius: isExpanded ? 5.5 : 4.0,
                    bottomRadius: isExpanded ? 22.0 : 12.0
                )
            )
            .onHover { hovering in
                collapseWorkItem?.cancel()
                if hovering {
                    withAnimation(springAnimation) {
                        isExpanded = true
                    }
                } else {
                    guard !isDraggingSlider else { return }
                    withAnimation(springAnimation) {
                        isExpanded = false
                    }
                }
            }
            // Dynamic island depth shadow
            .shadow(color: Color.black.opacity(isExpanded ? 0.55 : 0.28), radius: isExpanded ? 18 : 6, x: 0, y: isExpanded ? 6 : 2)
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

struct AudioSpectrumView: View {
    private let greenColor = Color(red: 0.22, green: 0.86, blue: 0.45)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let h1 = 3.0 + 8.5 * (0.5 + 0.5 * sin(time * 7.5))
            let h2 = 3.0 + 9.5 * (0.5 + 0.5 * sin(time * 5.2 + 1.2))
            let h3 = 3.0 + 8.0 * (0.5 + 0.5 * sin(time * 9.1 + 2.4))
            let h4 = 3.0 + 9.0 * (0.5 + 0.5 * sin(time * 6.3 + 0.7))

            HStack(alignment: .bottom, spacing: 2) {
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(greenColor)
                    .frame(width: 2.2, height: CGFloat(h1))
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(greenColor)
                    .frame(width: 2.2, height: CGFloat(h2))
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(greenColor)
                    .frame(width: 2.2, height: CGFloat(h3))
                RoundedRectangle(cornerRadius: 1.2)
                    .fill(greenColor)
                    .frame(width: 2.2, height: CGFloat(h4))
            }
            .frame(height: 15)
        }
    }
}

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let tR = max(0, topRadius)
        let bR = max(0, bottomRadius)

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left concave ear blending into menu bar / bezel
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tR, y: rect.minY + tR),
            control: CGPoint(x: rect.minX + tR, y: rect.minY)
        )
        // Left side line
        path.addLine(to: CGPoint(x: rect.minX + tR, y: rect.maxY - bR))
        // Bottom-left rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + tR + bR, y: rect.maxY),
            control: CGPoint(x: rect.minX + tR, y: rect.maxY)
        )
        // Bottom side line
        path.addLine(to: CGPoint(x: rect.maxX - tR - bR, y: rect.maxY))
        // Bottom-right rounded corner
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - tR, y: rect.maxY - bR),
            control: CGPoint(x: rect.maxX - tR, y: rect.maxY)
        )
        // Right side line
        path.addLine(to: CGPoint(x: rect.maxX - tR, y: rect.minY + tR))
        // Top-right concave ear blending into menu bar / bezel
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - tR, y: rect.minY)
        )
        // Top edge
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        return path
    }
}

#Preview {
    ContentView()
}

