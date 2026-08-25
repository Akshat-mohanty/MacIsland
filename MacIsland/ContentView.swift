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
    @AppStorage(AppDelegate.showsDockIconKey) private var showsDockIcon = false
    private let collapsedHeight: CGFloat = 31
    private let expandedHeight: CGFloat = 80
    
    var body: some View {
        ZStack(alignment: .top) {
            // Using a completely clear background so the window is transparent
            Color.clear
            
            // The Island Container
            HStack(alignment: .center) {
                if isExpanded {
                    if let artwork = mediaManager.artworkImage {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: mediaManager.isYouTube ? .fit : .fill)
                            .frame(width: mediaManager.isYouTube ? 28 : 44, height: mediaManager.isYouTube ? 28 : 44)
                            .clipShape(RoundedRectangle(cornerRadius: mediaManager.isYouTube ? 0 : 10))
                            .frame(width: 44, height: 44)
                            .padding(.leading, 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    } else {
                        Text("🎵")
                            .font(.system(size: 28))
                            .frame(width: 44, height: 44)
                            .padding(.leading, 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    }
                
                    // Content that appears when expanded
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mediaManager.title)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(mediaManager.artist.isEmpty ? "Unknown Artist" : mediaManager.artist)
                            .font(.caption)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                    .padding(.leading, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                    
                    Spacer()

                    HStack(spacing: 12) {
                        Button(action: { mediaManager.skipBackward() }) {
                            Image(systemName: "backward.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { mediaManager.togglePlayPause() }) {
                            Image(systemName: mediaManager.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        
                        Button(action: { mediaManager.skipForward() }) {
                            Image(systemName: "forward.fill")
                                .font(.title3)
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
                } else {
                    Spacer()
                }
                
            }
            // The collapsed height extends below the menu bar so there is no gap above the front app.
            .frame(width: isExpanded ? 400 : 200, height: isExpanded ? expandedHeight : collapsedHeight)
            .background(Color.black)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: isExpanded ? 40 : 20, bottomTrailingRadius: isExpanded ? 40 : 20, topTrailingRadius: 0))
            // Smooth spring animation for the dynamic island feel
            .animation(.spring(response: 0.4, dampingFraction: 0.6, blendDuration: 0), value: isExpanded)
            .onHover { hovering in
                guard hovering else {
                    isExpanded = false
                    return
                }

                isExpanded = true
            }
            // Add a subtle shadow to the island itself since we removed the window shadow
            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
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
        // Give the container a fixed size large enough to avoid clipping the expanded state and shadows
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

#Preview {
    ContentView()
}
