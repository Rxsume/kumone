// Sources/Kumone/Features/Player/NomandBackgroundView.swift
//
// Folia nomand (漫游) background view: the halftone-dot cover, with a
// theme-background veil on top.
//
// The halftone is rendered once per track on a background queue (see
// `NomandDitherer`) and cached, so a track change costs one render and a
// tuning tweak only re-renders when a value actually changed. While a
// new render is in flight the previous image stays up — no flash to a
// plain background — and the new one fades in.

import SwiftUI

/// The nomand halftone background for the luminous now-playing page:
/// halftone cover, then a veil of `background` at `overlayOpacity`
/// (Folia's overlay, 0.35 by default) on top.
struct NomandBackgroundView: View {
    var cover: PlatformImage?
    var songID: String?
    var tuning: NomandDitherer.Tuning
    var overlayOpacity: Double
    var background: Color

    @State private var halftone: PlatformImage?

    /// What triggers a re-render: the song, the cover image itself, or
    /// any tuning value.
    private struct Request: Hashable {
        var songID: String?
        var coverID: ObjectIdentifier?
        var tuning: NomandDitherer.Tuning
    }

    private var request: Request {
        Request(songID: songID, coverID: cover.map { ObjectIdentifier($0) }, tuning: tuning)
    }

    var body: some View {
        ZStack {
            background
            if let halftone {
                #if os(iOS)
                Image(uiImage: halftone)
                #else
                Image(nsImage: halftone)
                #endif
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
            background.opacity(overlayOpacity)
        }
        .animation(.easeInOut(duration: 0.3), value: halftone != nil)
        .task(id: request) {
            guard let cover else {
                halftone = nil
                return
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                NomandDitherer.halftoneImage(for: cover, songID: songID, tuning: tuning)
            }.value
            // A newer request may have started while this render ran;
            // only the latest one may assign.
            guard !Task.isCancelled else { return }
            halftone = rendered
        }
    }
}
