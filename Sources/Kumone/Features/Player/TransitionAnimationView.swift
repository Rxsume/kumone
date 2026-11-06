import SwiftUI

/// C11: a lightweight on-screen hint while a handover plays — a ring with a
/// spinning accent arc, centred over the now-playing page. The card outline
/// is the other half of the same feature and lives on `StageTrackCard`
/// (`transitionHighlighted`); this view only draws the ring.
///
/// The ring shows only when `isTransitioning` is true *and*
/// `settings.transitionAnimationRing` is on. There is currently no live
/// signal to drive `isTransitioning` (see `NowPlayingView.transitionInProgress`):
/// the engine reports transitions only as `transitionMidpoint` /
/// `transitionCompleted` events on a private `AsyncStream`, and the debug
/// model's plan is set when the next track is *planned*, not while the
/// overlap plays — so the view is built and mounted, but stays inert until
/// the engine publishes a transition-in-progress state. iOS has no handover
/// engine yet, so the ring cannot activate there in any case.
struct TransitionAnimationView: View {
    let isTransitioning: Bool
    /// Resolved theme accent, passed down from NowPlayingView (C12/C14).
    let accent: Color

    @EnvironmentObject private var settings: SettingsManager
    @State private var spinAngle = 0.0

    /// The spin stills in static mode, or when the transitions
    /// reduce-motion override says so (C4/C5); the ring itself stays put.
    private var motionStilled: Bool {
        settings.staticMode || settings.effectiveReduceMotionTransitions
    }

    var body: some View {
        if isTransitioning, settings.transitionAnimationRing {
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
        }
    }
}
