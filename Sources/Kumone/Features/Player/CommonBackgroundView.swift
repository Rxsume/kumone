// Sources/Kumone/Features/Player/CommonBackgroundView.swift
//
// Folia `common` （通用） background, re-implemented natively in SwiftUI.
//
// Folia source: `components/visualizer/backgrounds/common/`
// (`CommonBackground.tsx` and its geometric / particle layers). What
// Folia draws there: the theme solid colour, an optional blurred-cover
// "fluid" layer (cover blurred and zoomed, with a diagonal
// primary → transparent → secondary gradient and a theme-colour div
// over it), a field of seeded geometric shapes drifting slowly, small
// rising particles, and a radial vignette on top.
//
// The native version keeps the per-frame work trivial: the blurred
// cover is one static SwiftUI blur (never re-blurred per frame) and
// the shapes / particles ride a single `TimelineView(.animation)`
// whose positions are pure sine/cosine functions of the clock — no
// per-frame layout, allocation, or image work. Shape layout is
// seeded deterministically from the song id (FNV-1a + splitmix64), so
// a track always gets the same field. Static mode and
// `disableGeometric` drop the shapes and particles entirely, per the
// Folia behaviour of freezing the animated layers.

import SwiftUI

/// Folia `common` background: theme colour, optional blurred-cover
/// fluid layer, seeded drifting geometric shapes, rising particles,
/// and a vignette.
public struct CommonBackgroundView: View {
    public var cover: PlatformImage?
    public var background: Color
    public var primary: Color
    public var secondary: Color
    public var accent: Color
    public var songID: String?
    /// Opacity of the theme-colour div over the blurred-cover layer.
    public var opacity: Double
    public var useCoverColorBg: Bool
    public var disableVignette: Bool
    public var disableGeometric: Bool
    public var isStatic: Bool
    /// Live audio bands driving the shape pulse: circle → bass,
    /// square → lowMid, triangle → mid, cross → treble.
    public var audioLevels: (bass: Float, lowMid: Float, mid: Float, treble: Float)

    public init(
        cover: PlatformImage?,
        background: Color,
        primary: Color,
        secondary: Color,
        accent: Color,
        songID: String? = nil,
        opacity: Double = 0.75,
        useCoverColorBg: Bool = false,
        disableVignette: Bool = false,
        disableGeometric: Bool = false,
        isStatic: Bool = false,
        audioLevels: (bass: Float, lowMid: Float, mid: Float, treble: Float) = (0, 0, 0, 0)
    ) {
        self.cover = cover
        self.background = background
        self.primary = primary
        self.secondary = secondary
        self.accent = accent
        self.songID = songID
        self.opacity = opacity
        self.useCoverColorBg = useCoverColorBg
        self.disableVignette = disableVignette
        self.disableGeometric = disableGeometric
        self.isStatic = isStatic
        self.audioLevels = audioLevels
    }

    /// The seeded field for this song, recomputed (cheaply and
    /// deterministically) whenever the view re-evaluates.
    private var field: (shapes: [ShapeSpec], particles: [ParticleSpec]) {
        Self.seededField(songID: songID)
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                if useCoverColorBg, let cover {
                    coverLayer(cover: cover, size: geo.size)
                }
                // Shapes and particles only while animated: static mode
                // freezes the layers away entirely, matching the
                // Folia static behaviour for this mode.
                if !disableGeometric && !isStatic {
                    TimelineView(.animation) { context in
                        shapesLayer(
                            time: context.date.timeIntervalSinceReferenceDate,
                            size: geo.size
                        )
                    }
                }
                if !disableVignette {
                    vignette(size: geo.size)
                }
            }
        }
        .clipped()
    }

    // MARK: - Layers

    /// Blurred cover, zoomed 1.5x about the centre, with the diagonal
    /// primary → transparent → secondary gradient over it and the
    /// theme-colour div at `opacity` on top. Static SwiftUI blur: it
    /// is rendered once, not per frame.
    private func coverLayer(cover: PlatformImage, size: CGSize) -> some View {
        ZStack {
            Image(platformImage: cover)
                .resizable()
                .scaledToFill()
                .scaleEffect(1.5)
                .blur(radius: 40)
                .frame(width: size.width, height: size.height)
                .clipped()
            LinearGradient(
                stops: [
                    .init(color: primary, location: 0),
                    .init(color: .clear, location: 0.5),
                    .init(color: secondary, location: 1),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            background.opacity(opacity)
        }
    }

    /// Radial vignette: transparent out to 40%, black at 0.6 by the
    /// edge, so lyrics stay readable at the corners.
    private func vignette(size: CGSize) -> some View {
        RadialGradient(
            gradient: Gradient(stops: [
                .init(color: .clear, location: 0.4),
                .init(color: .black.opacity(0.6), location: 1.0),
            ]),
            center: .center,
            startRadius: 0,
            endRadius: max(size.width, size.height) * 0.75
        )
    }

    // MARK: - Shapes & particles

    private func shapesLayer(time: Double, size: CGSize) -> some View {
        ZStack {
            ForEach(field.shapes) { spec in
                shapeView(for: spec, time: time, size: size)
            }
            ForEach(field.particles) { particle in
                particleView(for: particle, time: time, size: size)
            }
        }
    }

    @ViewBuilder
    private func shapeView(for spec: ShapeSpec, time: Double, size: CGSize) -> some View {
        let color = [primary, secondary, accent][spec.colorIndex % 3]
            .opacity(spec.opacity)
        let offset = driftOffset(spec: spec, time: time, size: size)
        let scale = 0.95 + Double(audioBand(for: spec.kind)) * 0.5
        Group {
            switch spec.kind {
            case 0:
                Circle().fill(color)
            case 1:
                RoundedRectangle(cornerRadius: 10).fill(color)
            case 2:
                Triangle().fill(color)
            default:
                Cross().fill(color)
            }
        }
        .frame(width: spec.size, height: spec.size)
        .scaleEffect(scale)
        .position(
            x: spec.baseX * size.width + offset.width,
            y: spec.baseY * size.height + offset.height
        )
    }

    private func particleView(for particle: ParticleSpec, time: Double, size: CGSize) -> some View {
        // Rises slowly and loops: y wraps from the bottom back to the
        // top, so the field never runs out of particles.
        let rawY = particle.baseY - time * particle.speed
        let wrappedY = rawY.truncatingRemainder(dividingBy: 1)
        let y = (wrappedY < 0 ? wrappedY + 1 : wrappedY) * size.height
        let x = particle.baseX * size.width
            + CGFloat(8 * sin(2 * Double.pi * time / 47 + particle.phase))
        return Circle()
            .fill(Color.white.opacity(0.35))
            .frame(width: particle.size, height: particle.size)
            .position(x: x, y: y)
    }

    /// Slow looping drift: one sine/cosine cycle per shape period
    /// (30–60s), so a shape wanders and returns instead of marching
    /// off-screen.
    private func driftOffset(spec: ShapeSpec, time: Double, size: CGSize) -> CGSize {
        let angle = 2 * Double.pi * time / spec.period + spec.phase
        return CGSize(
            width: CGFloat(sin(angle)) * spec.driftX * size.width,
            height: CGFloat(cos(angle * 0.9)) * spec.driftY * size.height
        )
    }

    /// Audio band for a shape kind: circle → bass, square → lowMid,
    /// triangle → mid, cross → treble.
    private func audioBand(for kind: Int) -> Float {
        switch kind {
        case 0: return audioLevels.bass
        case 1: return audioLevels.lowMid
        case 2: return audioLevels.mid
        default: return audioLevels.treble
        }
    }

    // MARK: - Seeded field

    private struct ShapeSpec: Identifiable {
        var id: Int
        /// 0 circle, 1 square, 2 triangle, 3 cross.
        var kind: Int
        var size: CGFloat
        var opacity: Double
        var baseX: CGFloat
        var baseY: CGFloat
        /// Drift period in seconds (30–60).
        var period: Double
        var phase: Double
        /// Drift amplitude as a fraction of the view size.
        var driftX: CGFloat
        var driftY: CGFloat
        var colorIndex: Int
    }

    private struct ParticleSpec: Identifiable {
        var id: Int
        var baseX: CGFloat
        var baseY: CGFloat
        /// Dot diameter in points (1–5).
        var size: CGFloat
        /// Fraction of the view height risen per second.
        var speed: Double
        var phase: Double
    }

    private static func seededField(songID: String?) -> (shapes: [ShapeSpec], particles: [ParticleSpec]) {
        var rng = SplitMix64(seed: fnv1a(songID ?? ""))
        var shapes: [ShapeSpec] = []
        shapes.reserveCapacity(15)
        for i in 0..<15 {
            shapes.append(ShapeSpec(
                id: i,
                kind: Int(rng.next() % 4),
                size: CGFloat(rng.nextDouble(in: 40...140)),
                opacity: rng.nextDouble(in: 0.11...0.19),
                baseX: CGFloat(rng.nextDouble(in: 0.05...0.95)),
                baseY: CGFloat(rng.nextDouble(in: 0.05...0.95)),
                period: rng.nextDouble(in: 30...60),
                phase: rng.nextDouble(in: 0...(2 * Double.pi)),
                driftX: CGFloat(rng.nextDouble(in: 0.02...0.08)),
                driftY: CGFloat(rng.nextDouble(in: 0.02...0.08)),
                colorIndex: Int(rng.next() % 3)
            ))
        }
        var particles: [ParticleSpec] = []
        particles.reserveCapacity(20)
        for i in 0..<20 {
            particles.append(ParticleSpec(
                id: i,
                baseX: CGFloat(rng.nextDouble(in: 0...1)),
                baseY: CGFloat(rng.nextDouble(in: 0...1)),
                size: CGFloat(rng.nextDouble(in: 1...5)),
                // A full rise takes ~40–90s.
                speed: rng.nextDouble(in: 1.0 / 90...1.0 / 40),
                phase: rng.nextDouble(in: 0...(2 * Double.pi))
            ))
        }
        return (shapes, particles)
    }

    /// FNV-1a over the song id: stable across launches, unlike
    /// `Hasher`, so a track always gets the same field.
    private static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }

    /// splitmix64: tiny deterministic PRNG for the seeded field.
    private struct SplitMix64 {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }

        mutating func nextDouble() -> Double {
            Double(next() >> 11) / Double(1 << 53)
        }

        mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
            range.lowerBound + nextDouble() * (range.upperBound - range.lowerBound)
        }
    }

    // MARK: - Shape paths

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    private struct Cross: Shape {
        func path(in rect: CGRect) -> Path {
            let thickness = rect.width * 0.28
            var path = Path()
            path.addRect(CGRect(
                x: rect.midX - thickness / 2, y: rect.minY,
                width: thickness, height: rect.height
            ))
            path.addRect(CGRect(
                x: rect.minX, y: rect.midY - thickness / 2,
                width: rect.width, height: thickness
            ))
            return path
        }
    }
}
