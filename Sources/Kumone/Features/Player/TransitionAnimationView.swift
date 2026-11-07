import SwiftUI

/// C11: a lightweight on-screen hint while a handover plays — a ring with a
/// spinning accent arc, centred over the now-playing page. The card outline
/// is the other half of the same feature and lives on `StageTrackCard`
/// (`transitionHighlighted`); this view only draws the ring.
///
/// The ring shows only when `isTransitioning` is true *and*
/// `settings.effectiveTransitionAnimationRing` is on. `isTransitioning`
/// comes from `NowPlayingView.transitionInProgress`, which reads the
/// player's published signal: on iOS the dual-deck crossfade engine drives
/// it (and it stays false while crossfade is switched off); on macOS the
/// AutoMix engine does. The ring therefore only appears during an actual
/// track transition, never on a plain tap.
struct TransitionAnimationView: View {
    let isTransitioning: Bool
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color

    @EnvironmentObject private var settings: SettingsManager
    @State private var spinAngle = 0.0
    /// The ring is only a brief hint that a handover started: the overlap
    /// itself runs up to 8s, and a spinning ring over the new song's lyrics
    /// for all of it reads as a loading spinner. It fades out after one
    /// rotation (~1.5s) while the crossfade keeps running underneath.
    @State private var visible = true

    /// The spin stills in static mode, or when the transitions
    /// reduce-motion override says so (C4/C5); the ring itself stays put.
    private var motionStilled: Bool {
        settings.effectiveStaticMode || settings.effectiveReduceMotionTransitions
    }

    var body: some View {
        if isTransitioning, settings.effectiveTransitionAnimationRing, visible {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(spinAngle))
            }
            .frame(width: 120, height: 120)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !motionStilled else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            }
            .onDisappear {
                spinAngle = 0
            }
            .task {
                try? await Task.sleep(for: .milliseconds(1500))
                withAnimation(.easeOut(duration: 0.3)) {
                    visible = false
                }
            }
        }
    }
}
