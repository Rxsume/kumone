// Sources/Kumone/Features/Player/LatentBackgroundView.swift
//
// Folia latent (潜流) background for the luminous now-playing page:
// the flowing, morphing smoke-like dot field behind the classic
// visualizer in the reference video.
//
// What Folia actually draws there (`components/visualizer/backgrounds/
// latent/LatentBackground.tsx`, the DEFAULT background mode —
// `DEFAULT_VISUALIZER_BACKGROUND_MODE = 'latent'`): two cover-coloured
// Paper shaders, layered — an animated MeshGradient (distortion 0.8,
// swirl 0.1, speed 0.3) with a warp Dithering shader on top
// (shape "warp", 4x4 Bayer, size 2.5, speed 0.1, soft-light blend,
// opacity 0.55), then a theme-background veil at 0.35.
//
// This is NOT the nomand HalftoneDots shader: that one declares a time
// uniform but never consumes it, so it is static in practice. The motion
// in the video — the dot field decorrelating within a second, the smoke
// re-forming over ~5s, and the near-freeze when playback pauses — is
// the latent pair. The shipped Rumxs luminous page only had the static
// nomand halftone, which is why the cover never moved.
//
// The port is one small Metal fragment shader, compiled at runtime from
// a source string (`MTLDevice.makeLibrary(source:)`, iOS 8+), so no
// .metal file and no Xcode project change is needed: the same
// domain-warped fbm field drives both the mesh colours and the Bayer
// dither warp, so the dots morph with the smoke exactly like the video.
// It renders at half point resolution, 30fps, and costs one fullscreen
// quad — no CPU image work per frame, no per-frame tokenizer or blur.
// Paused playback slows the flow to 0.12x (Folia's
// `PAUSED_SPEED_SCALE`); static mode / Reduce Motion freezes it after
// the first frame (Folia's speed 0).

#if os(iOS)

import Metal
import MetalKit
import SwiftUI
import UIKit

/// The latent tuning as one value (Folia's `latent_background_tuning`).
/// Built by `SettingsManager.latentTuning` from the `effective*`
/// properties; the renderer only ever sees this struct, never the store.
struct LatentTuning: Equatable {
    var displayMode: LatentDisplayMode = .both
    var colorSource: LatentColorSource = .coverTheme
    var overlayEnabled: Bool = true
    var overlayOpacity: Double = 0.35
    var ditheringSpeed: Double = 0.1
    var ditheringAudioSpeed: Double = 1.2
    var ditheringSize: Double = 2.5
    var ditheringOpacity: Double = 0.55
    var meshSpeed: Double = 0.3
    var meshAudioSpeed: Double = 2.0
    var meshDistortion: Double = 0.8
    var meshSwirl: Double = 0.1
    var enhancedBeatResponse: Bool = true
}

/// The latent flowing background: cover-coloured smoke + warp dither,
/// with a theme-background veil on top (Folia's 0.35 overlay).
struct LatentBackgroundView: View {
    var primary: Color
    var secondary: Color
    var accent: Color
    var background: Color
    var isPlaying: Bool
    var isStatic: Bool
    var tuning: LatentTuning = LatentTuning()

    /// Metal is unavailable on the simulator without a GPU device in
    /// some configurations; the plain background colour is the fallback
    /// there (and anywhere the shader fails to compile).
    private static let metalAvailable = MTLCreateSystemDefaultDevice() != nil

    /// The mesh palette for the current colour source. Cover-theme is
    /// the shipped behaviour (cover pair + theme accent + background
    /// blends); cover-only builds all six stops from the two extracted
    /// cover colours — Folia extracts six representative colours from
    /// the cover, Rumxs extracts two, so the rest are blends of those.
    private var palette: [Color] {
        tuning.colorSource == .coverOnly
            ? Self.coverOnlyPalette(primary: primary, secondary: secondary)
            : Self.meshPalette(
                primary: primary, secondary: secondary,
                accent: accent, background: background
            )
    }

    /// Dithering back colour: the theme background for cover-theme, the
    /// second cover colour for cover-only (Folia takes both dither
    /// colours from the cover then).
    private var ditherBack: Color {
        tuning.colorSource == .coverOnly ? secondary : background
    }

    var body: some View {
        ZStack {
            background
            if Self.metalAvailable {
                // Poll the live band levels ~15x/s and hand them to the
                // renderer; the coordinator smooths them per frame (Folia
                // reads its analyser inside its own RAF loop). The read
                // must happen here — SwiftUI runs on the main actor and
                // `AudioSpectrum` is @MainActor — not in the Metal
                // coordinator. A frozen page does not poll.
                TimelineView(
                    .animation(minimumInterval: 1.0 / 15.0, paused: isStatic)
                ) { _ in
                    LatentBackgroundMetalView(
                        palette: palette,
                        ditherBack: ditherBack,
                        background: background,
                        isPlaying: isPlaying,
                        isStatic: isStatic,
                        tuning: tuning,
                        audioLevels: (
                            bass: AudioSpectrum.shared.level(at: 0),
                            lowMid: AudioSpectrum.shared.level(at: 1),
                            mid: AudioSpectrum.shared.level(at: 2),
                            treble: AudioSpectrum.shared.level(at: 3)
                        )
                    )
                }
            }
        }
    }

    /// Folia's latent mesh takes six cover colours; Rumxs only extracts
    /// two (primary / secondary) plus the theme accent, so the other
    /// three are blends of those — the shader mixes them by noise, so
    /// the field stays cover-coloured and dark either way.
    static func meshPalette(
        primary: Color, secondary: Color, accent: Color, background: Color
    ) -> [Color] {
        [
            primary,
            secondary,
            accent,
            Self.mix(primary, background, 0.55),
            Self.mix(accent, secondary, 0.5),
            background,
        ]
    }

    /// Six mesh stops from the two extracted cover colours only (see
    /// `palette`): Folia's cover-only mode takes all six from the cover.
    static func coverOnlyPalette(primary: Color, secondary: Color) -> [Color] {
        [
            primary,
            secondary,
            Self.mix(primary, secondary, 0.5),
            Self.mix(primary, secondary, 0.25),
            Self.mix(secondary, primary, 0.75),
            Self.mix(primary, secondary, 0.65),
        ]
    }

    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        let ra = rgba(a), rb = rgba(b)
        return Color(
            red: ra.r + (rb.r - ra.r) * t,
            green: ra.g + (rb.g - ra.g) * t,
            blue: ra.b + (rb.b - ra.b) * t
        )
    }

    static func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return (0, 0, 0, 1)
        }
        return (Double(r), Double(g), Double(b), Double(a))
    }
}

// MARK: - Metal view

/// The MTKView host. All Metal work happens here; the SwiftUI side only
/// passes colours and play state in.
private struct LatentBackgroundMetalView: UIViewRepresentable {
    var palette: [Color]
    var ditherBack: Color
    var background: Color
    var isPlaying: Bool
    var isStatic: Bool
    var tuning: LatentTuning
    /// Live band levels (0...1), polled by the SwiftUI side ~15x/s.
    var audioLevels: (bass: Float, lowMid: Float, mid: Float, treble: Float)

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Half point resolution: the field is soft smoke + small dots,
        // so the upscale is invisible, and the fragment cost quarters.
        view.contentScaleFactor = 0.5
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColor(
            red: Double(LatentBackgroundView.rgba(background).r),
            green: Double(LatentBackgroundView.rgba(background).g),
            blue: Double(LatentBackgroundView.rgba(background).b),
            alpha: 1
        )
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.compileIfNeeded()
        context.coordinator.apply(
            palette: palette, ditherBack: ditherBack, background: background,
            isPlaying: isPlaying, isStatic: isStatic,
            tuning: tuning, audioLevels: audioLevels, view: view
        )
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.apply(
            palette: palette, ditherBack: ditherBack, background: background,
            isPlaying: isPlaying, isStatic: isStatic,
            tuning: tuning, audioLevels: audioLevels, view: view
        )
    }

    // MARK: - Coordinator (MTKViewDelegate + renderer)

    final class Coordinator: NSObject, MTKViewDelegate {
        weak var view: MTKView?

        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var compileStarted = false

        /// Seconds of shader time. Two clocks: the mesh (fluid) field
        /// and the dither (pixel) layer advance at their own speeds
        /// (Folia's `meshSpeed` / `ditheringSpeed`), so the two layers
        /// can move independently. Advanced in `draw(in:)` so the flow
        /// follows the display link, never a SwiftUI timer.
        private var timeMesh: Float = 0
        private var timeDither: Float = 0
        private var lastDrawTimestamp: CFTimeInterval?

        private var meshColors: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 6)
        private var ditherFront: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
        private var ditherBackColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
        private var backgroundColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
        private var isPlaying = true
        private var isStatic = false
        private var tuning = LatentTuning()
        private var audioLevels: (bass: Float, lowMid: Float, mid: Float, treble: Float) = (0, 0, 0, 0)

        /// Smoothed audio terms, eased per frame in `draw(in:)` (Folia's
        /// RAF-loop smoothing: power 0.12, bass 0.16, mid 0.13 per frame
        /// at 60fps, dt-scaled here).
        private var smoothedPower: Float = 0
        private var smoothedBass: Float = 0
        private var smoothedMid: Float = 0
        private var smoothedBeat: Float = 0
        private var previousEnergy: Float = 0
        private var onsetPulse: Float = 0

        /// Compile the shader once, off the main thread: a small source
        /// still takes tens of milliseconds, and the first frame must not
        /// stall the player page. Until it lands the view shows its clear
        /// colour (the background colour), never a flash.
        func compileIfNeeded() {
            guard !compileStarted else { return }
            compileStarted = true
            guard let device = MTLCreateSystemDefaultDevice() else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let pipeline = Self.makePipeline(device: device)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.commandQueue = device.makeCommandQueue()
                    self.pipelineState = pipeline
                    // A static page never gets a display-link tick, so
                    // draw its one frozen frame explicitly.
                    self.view?.draw()
                }
            }
        }

        func apply(
            palette: [Color], ditherBack: Color, background: Color,
            isPlaying: Bool, isStatic: Bool,
            tuning: LatentTuning,
            audioLevels: (bass: Float, lowMid: Float, mid: Float, treble: Float),
            view: MTKView
        ) {
            self.isPlaying = isPlaying
            let wasStatic = self.isStatic
            self.isStatic = isStatic
            self.tuning = tuning
            self.audioLevels = audioLevels
            meshColors = (0..<6).map { index in
                let color = index < palette.count ? palette[index] : background
                let c = LatentBackgroundView.rgba(color)
                return SIMD4<Float>(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
            }
            // Folia latent: dithering front = primary cover colour,
            // dithering back = theme background colour (cover-theme) or
            // the second cover colour (cover-only).
            ditherFront = meshColors.first ?? SIMD4<Float>(1, 1, 1, 1)
            let back = LatentBackgroundView.rgba(ditherBack)
            ditherBackColor = SIMD4<Float>(Float(back.r), Float(back.g), Float(back.b), Float(back.a))
            let bg = LatentBackgroundView.rgba(background)
            backgroundColor = SIMD4<Float>(Float(bg.r), Float(bg.g), Float(bg.b), Float(bg.a))
            view.clearColor = MTLClearColor(red: Double(bg.r), green: Double(bg.g), blue: Double(bg.b), alpha: 1)
            if isStatic {
                // Freeze after the current frame: the last drawn frame
                // stays on screen, exactly like Folia's speed 0.
                view.isPaused = true
                if !wasStatic { view.draw() }
            } else {
                view.isPaused = false
            }
        }

        // MARK: MTKViewDelegate

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // The shader reads the drawable size from the render target
            // each frame, so nothing to do here.
        }

        func draw(in view: MTKView) {
            guard let pipelineState,
                  let commandQueue,
                  let drawable = view.currentDrawable,
                  let passDescriptor = view.currentRenderPassDescriptor,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
            else { return }

            // Advance shader time: full speed while playing, 0.12x while
            // paused (Folia `PAUSED_SPEED_SCALE`), frozen while static
            // (the view is paused then, so this never runs — the guard
            // is here so a manual `draw()` cannot lurch the field).
            //
            // Audio reactivity (Folia `LatentBackground.tsx`): broadband
            // energy is the weighted band sum (^0.55); the onset pulse
            // jumps on a rising edge and decays; the beat amount eases
            // toward the audio target (attack 0.42, release 0.14) and
            // blends each layer's base speed toward its audio max.
            // Rumxs has four bands (60–250 / 250–800 / 800–2500 /
            // 2500–8000 Hz) for Folia's five — the mid band stands in
            // for vocal as well (weights 0.22 / 0.18 / 0.50 / 0.10).
            // Speeds are scaled so the Folia defaults (mesh 0.3, dither
            // 0.1) reproduce the shipped Rumxs flow rate.
            let now = CACurrentMediaTime()
            if let last = lastDrawTimestamp {
                let dt = min(max(now - last, 0), 0.1)
                if !isStatic {
                    let dt60 = Float(dt * 60)
                    func eased(_ current: Float, toward target: Float, factor: Float) -> Float {
                        current + (target - current) * (1 - pow(1 - factor, dt60))
                    }
                    smoothedBass = eased(smoothedBass, toward: audioLevels.bass, factor: 0.16)
                    smoothedMid = eased(smoothedMid, toward: audioLevels.mid, factor: 0.13)
                    let energy = pow(
                        audioLevels.bass * 0.22 + audioLevels.lowMid * 0.18
                            + audioLevels.mid * 0.5 + audioLevels.treble * 0.1,
                        0.55
                    )
                    smoothedPower = eased(smoothedPower, toward: energy, factor: 0.12)
                    onsetPulse = max(
                        onsetPulse * pow(0.84, dt60),
                        min(max((energy - previousEnergy) * 7, 0), 1)
                    )
                    previousEnergy = energy
                    let audioTarget: Float
                    if tuning.enhancedBeatResponse {
                        audioTarget = min(max(energy * 0.42 + onsetPulse * 0.85, 0), 1)
                    } else {
                        audioTarget = min(max(energy, 0), 1)
                    }
                    smoothedBeat = eased(
                        smoothedBeat, toward: audioTarget,
                        factor: audioTarget > smoothedBeat ? 0.42 : 0.14
                    )
                    let playRate: Float = isPlaying ? 1.0 : 0.12
                    let meshSpeed = Float(tuning.meshSpeed)
                        + (Float(tuning.meshAudioSpeed) - Float(tuning.meshSpeed)) * smoothedBeat
                    let ditherSpeed = Float(tuning.ditheringSpeed)
                        + (Float(tuning.ditheringAudioSpeed) - Float(tuning.ditheringSpeed)) * smoothedBeat
                    timeMesh += Float(dt) * (meshSpeed / 0.3) * playRate
                    timeDither += Float(dt) * (ditherSpeed / 0.1) * playRate
                }
            }
            lastDrawTimestamp = now

            // Per-frame audio terms (Folia's formulas): the bass shrinks
            // the dither cells and lifts the dither opacity; broadband
            // power widens the fluid distortion; mids widen the swirl.
            let ditherSize = max(
                0.5, Float(tuning.ditheringSize) - smoothedBass * Float(tuning.ditheringSize) * 0.34
            )
            let ditherOpacity = min(1, Float(tuning.ditheringOpacity) + smoothedBass * 0.25)
            let distortion = Float(tuning.meshDistortion) + smoothedPower * 0.62
            let swirl = Float(tuning.meshSwirl) + smoothedMid * 0.38
            let layerMode: Float
            switch tuning.displayMode {
            case .both: layerMode = 0
            case .dithering: layerMode = 1
            case .mesh: layerMode = 2
            }

            var uniforms = LatentUniforms(
                mesh0: meshColors[0], mesh1: meshColors[1], mesh2: meshColors[2],
                mesh3: meshColors[3], mesh4: meshColors[4], mesh5: meshColors[5],
                ditherBack: ditherBackColor, ditherFront: ditherFront,
                background: backgroundColor,
                resolution: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
                timeMesh: timeMesh, timeDither: timeDither,
                ditherSize: ditherSize, ditherOpacity: ditherOpacity,
                overlayOpacity: tuning.overlayEnabled ? Float(tuning.overlayOpacity) : 0,
                distortion: distortion, swirl: swirl, layerMode: layerMode,
                pad: SIMD2<Float>(0, 0)
            )
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LatentUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Pipeline

        private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: latentShaderSource, options: nil)
                guard let vertex = library.makeFunction(name: "latentVertex"),
                      let fragment = library.makeFunction(name: "latentFragment")
                else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                // Compilation failure leaves the view on its clear colour;
                // the caller never shows an error for a background.
                return nil
            }
        }
    }
}

// MARK: - Uniforms

/// Must match the `LatentUniforms` struct in the shader below, field for
/// field and in order: nine float4s, one float2, eight floats, one float2
/// pad — 192 bytes, 16-byte aligned throughout.
private struct LatentUniforms {
    var mesh0: SIMD4<Float>
    var mesh1: SIMD4<Float>
    var mesh2: SIMD4<Float>
    var mesh3: SIMD4<Float>
    var mesh4: SIMD4<Float>
    var mesh5: SIMD4<Float>
    var ditherBack: SIMD4<Float>
    var ditherFront: SIMD4<Float>
    var background: SIMD4<Float>
    var resolution: SIMD2<Float>
    var timeMesh: Float
    var timeDither: Float
    var ditherSize: Float
    var ditherOpacity: Float
    var overlayOpacity: Float
    var distortion: Float
    var swirl: Float
    var layerMode: Float
    var pad: SIMD2<Float>
}

// MARK: - Shader

/// One fragment shader: a domain-warped fbm smoke field in the cover
/// palette, plus a Bayer warp dither over it, soft-light blended, under
/// a background veil.
///
/// The same warp field (`q`) moves both layers, so the dot pattern
/// re-forms with the smoke instead of sitting still on top of it — that
/// is the motion the reference video shows. Drift rates are tuned so the
/// field visibly re-forms over ~5s while playing (the video's
/// low-frequency field decorrelates in ~4s); `distortion` / `swirl`
/// scale the warp strength the way Folia's mesh tuning does.
private let latentShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct LatentUniforms {
    float4 mesh0;
    float4 mesh1;
    float4 mesh2;
    float4 mesh3;
    float4 mesh4;
    float4 mesh5;
    float4 ditherBack;
    float4 ditherFront;
    float4 background;
    float2 resolution;
    float timeMesh;
    float timeDither;
    float ditherSize;
    float ditherOpacity;
    float overlayOpacity;
    float distortion;
    float swirl;
    float layerMode;
    float2 pad;
};

struct VSOut {
    float4 position [[position]];
};

vertex VSOut latentVertex(uint vid [[vertex_id]]) {
    // Fullscreen triangle: (0,0), (2,0), (0,2) in clip space.
    float2 pos = float2(float((vid << 1) & 2), float(vid & 2));
    VSOut out;
    out.position = float4(pos * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float fbm(float2 p) {
    float v = 0.0;
    float a = 0.5;
    for (int i = 0; i < 3; i++) {
        v += a * vnoise(p);
        p = p * 2.03 + float2(19.19, 7.7);
        a *= 0.5;
    }
    return v;
}

float softLightChannel(float b, float s) {
    if (s <= 0.5) {
        return b - (1.0 - 2.0 * s) * b * (1.0 - b);
    }
    float d = (b <= 0.25) ? ((16.0 * b - 12.0) * b + 4.0) * b : sqrt(b);
    return b + (2.0 * s - 1.0) * (d - b);
}

float3 softLight(float3 b, float3 s) {
    return float3(
        softLightChannel(b.r, s.r),
        softLightChannel(b.g, s.g),
        softLightChannel(b.b, s.b)
    );
}

fragment float4 latentFragment(VSOut in [[stage_in]], constant LatentUniforms &u [[buffer(0)]]) {
    float2 uv = in.position.xy / u.resolution;
    float aspect = u.resolution.x / u.resolution.y;
    // Feature scale: ~1-2 smoke blobs across the screen.
    float2 p = (uv - 0.5) * float2(aspect, 1.0) * 1.6;
    float t = u.timeMesh;
    // Slow swirl: the whole field turns almost imperceptibly, the way
    // Folia's mesh swirl does (0.1 here, so one turn takes minutes).
    float ang = u.swirl * 0.15 * t;
    float ca = cos(ang), sa = sin(ang);
    p = float2(p.x * ca - p.y * sa, p.x * sa + p.y * ca);

    // Domain warp, drifting slowly: this field is the flow. The drift
    // rates (≈0.11 / 0.05 units per second) re-form the field over
    // ~5s, matching the reference video; distortion / swirl scale the
    // warp the way Folia's mesh tuning does.
    float warpStrength = 1.0 + u.distortion;
    float2 q = float2(
        fbm(p * 0.9 + float2(0.0, t * 0.11)),
        fbm(p * 0.9 + float2(5.2, -t * 0.09))
    );
    float2 r = float2(
        fbm(p * 0.9 + warpStrength * q + float2(1.7, 9.2) + t * 0.05),
        fbm(p * 0.9 + warpStrength * q + float2(8.3, 2.8) - t * 0.04)
    );

    // Mesh gradient: five palette stops mixed by the warped field, plus
    // the dark anchor for depth. (Folia's MeshGradient blends six cover
    // colours the same way.)
    float3 col = mix(u.mesh0.rgb, u.mesh1.rgb, smoothstep(0.25, 0.75, r.x));
    col = mix(col, u.mesh2.rgb, smoothstep(0.30, 0.85, r.y));
    col = mix(col, u.mesh3.rgb, smoothstep(0.55, 0.95, fbm(p * 0.9 + warpStrength * q + float2(3.1, 4.7))));
    col = mix(col, u.mesh4.rgb, smoothstep(0.60, 1.00, q.x * q.y));
    col = mix(col, u.mesh5.rgb, smoothstep(0.75, 1.00, fbm(p * 0.9 + warpStrength * q + float2(6.7, 1.3))));
    // Gentle vignette so the lyrics stay readable at the edges.
    float vig = 1.0 - 0.30 * dot(uv - 0.5, uv - 0.5) * 2.0;
    col *= clamp(vig, 0.70, 1.0);

    // Warp dither: the same field offsets the dot grid, so the dots
    // morph with the smoke (Folia's Dithering "warp" shape). Cell size
    // is in 720p-reference pixels, so the dot pitch does not depend on
    // the render resolution. The dither layer also drifts on its own
    // clock, so the pixel layer can move at its own speed.
    float2 ditherPx = uv * u.resolution + (q - 0.5) * 24.0
        + float2(sin(u.timeDither * 0.13), cos(u.timeDither * 0.11)) * 6.0;
    float cell = u.ditherSize * u.resolution.y / 720.0;
    float2 cellPos = ditherPx / cell;
    int bx = int(mod(floor(cellPos.x), 4.0));
    int by = int(mod(floor(cellPos.y), 4.0));
    float bayer[16] = {
        0.0, 8.0, 2.0, 10.0,
        12.0, 4.0, 14.0, 6.0,
        3.0, 11.0, 1.0, 9.0,
        15.0, 7.0, 13.0, 5.0
    };
    float threshold = (bayer[by * 4 + bx] + 0.5) / 16.0;
    float lum = dot(col, float3(0.2126, 0.7152, 0.0722));
    float3 ditherCol = mix(u.ditherBack.rgb, u.ditherFront.rgb, step(threshold, lum));

    // Display layers (Folia `displayMode`): mesh only skips the dither
    // composite; dither only draws the warp-dithered pattern over the
    // warped field's luminance, at opacity 1 (Folia forces the dither
    // opacity to 1 when the mesh is hidden).
    if (u.layerMode > 1.5) {
        col = mix(col, u.background.rgb, u.overlayOpacity);
        return float4(col, 1.0);
    }
    if (u.layerMode > 0.5) {
        float lumOnly = clamp(r.x, 0.0, 1.0);
        float3 ditherOnly = mix(u.ditherBack.rgb, u.ditherFront.rgb, step(threshold, lumOnly));
        col = mix(ditherOnly, u.background.rgb, u.overlayOpacity);
        return float4(col, 1.0);
    }

    // Folia blends the dither layer over the mesh in soft-light at
    // 0.55, then veils everything with the background at 0.35.
    col = mix(col, softLight(col, ditherCol), u.ditherOpacity);
    col = mix(col, u.background.rgb, u.overlayOpacity);
    return float4(col, 1.0);
}
"""

#endif
