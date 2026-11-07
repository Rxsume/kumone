// Sources/Kumone/Features/Player/SoraBackgroundView.swift
//
// Folia `sora` （空） background, re-implemented natively with Metal.
//
// Folia source: `components/visualizer/backgrounds/sora/`
// (`SoraBackground.tsx`). Folia draws 150 drifting, blinking stars
// as GL_POINTS on a solid background — black in dark mode, white in
// light mode — with ~10% of the stars in the accent colour and the
// rest in the primary colour. The stars drift horizontally at
// per-star speeds and blink; Folia freezes `u_time` when paused or
// static.
//
// The port follows the `LatentBackgroundView` pattern exactly: an
// MTKView + Coordinator, the shader compiled at runtime from a source
// string (`MTLDevice.makeLibrary(source:)`), 30fps, half point
// resolution, time advanced in `draw(in:)`. Each star's speed, size,
// drift phase, and blink rate come from a hash of its vertex id, so
// the field is stable without any per-frame CPU state. The fragment
// shader draws a soft round point (smoothstep falloff) with
// pre-multiplied alpha, additive-ish over the solid background clear
// colour. Static mode pauses the view after one manual draw, exactly
// like latent. There is no `isPlaying` param here: time advances
// whenever the view is not static.

#if os(iOS)

import Metal
import MetalKit
import SwiftUI
import UIKit

/// Folia `sora` background: 150 drifting, blinking stars as Metal
/// points on a solid background colour.
public struct SoraBackgroundView: View {
    public var primary: Color
    public var accent: Color
    public var background: Color
    public var isStatic: Bool
    /// When true, render only the solid `background` colour — no stars.
    public var blank: Bool

    /// Metal is unavailable on the simulator without a GPU device in
    /// some configurations; the plain background colour is the fallback
    /// there (and anywhere the shader fails to compile).
    private static let metalAvailable = MTLCreateSystemDefaultDevice() != nil

    public init(
        primary: Color,
        accent: Color,
        background: Color,
        isStatic: Bool = false,
        blank: Bool = false
    ) {
        self.primary = primary
        self.accent = accent
        self.background = background
        self.isStatic = isStatic
        self.blank = blank
    }

    public var body: some View {
        ZStack {
            background
            if !blank && Self.metalAvailable {
                SoraBackgroundMetalView(
                    primary: primary,
                    accent: accent,
                    background: background,
                    isStatic: isStatic
                )
            }
        }
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
/// passes colours and static state in.
private struct SoraBackgroundMetalView: UIViewRepresentable {
    var primary: Color
    var accent: Color
    var background: Color
    var isStatic: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        // Half point resolution: the stars are soft round points, so
        // the upscale is invisible, and the fragment cost quarters.
        view.contentScaleFactor = 0.5
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColor(
            red: Double(SoraBackgroundView.rgba(background).r),
            green: Double(SoraBackgroundView.rgba(background).g),
            blue: Double(SoraBackgroundView.rgba(background).b),
            alpha: 1
        )
        view.delegate = context.coordinator
        context.coordinator.view = view
        context.coordinator.compileIfNeeded()
        context.coordinator.apply(
            primary: primary, accent: accent, background: background,
            isStatic: isStatic, view: view
        )
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.apply(
            primary: primary, accent: accent, background: background,
            isStatic: isStatic, view: view
        )
    }

    // MARK: - Coordinator (MTKViewDelegate + renderer)

    final class Coordinator: NSObject, MTKViewDelegate {
        weak var view: MTKView?

        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var compileStarted = false

        /// Seconds of shader time. Advanced in `draw(in:)` so the
        /// stars follow the display link, never a SwiftUI timer.
        private var time: Float = 0
        private var lastDrawTimestamp: CFTimeInterval?

        private var primaryColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
        private var accentColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)
        private var isStatic = false

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

        func apply(primary: Color, accent: Color, background: Color, isStatic: Bool, view: MTKView) {
            let wasStatic = self.isStatic
            self.isStatic = isStatic
            let primaryRGBA = SoraBackgroundView.rgba(primary)
            primaryColor = SIMD4<Float>(
                Float(primaryRGBA.r), Float(primaryRGBA.g),
                Float(primaryRGBA.b), Float(primaryRGBA.a)
            )
            let accentRGBA = SoraBackgroundView.rgba(accent)
            accentColor = SIMD4<Float>(
                Float(accentRGBA.r), Float(accentRGBA.g),
                Float(accentRGBA.b), Float(accentRGBA.a)
            )
            let bg = SoraBackgroundView.rgba(background)
            view.clearColor = MTLClearColor(red: Double(bg.r), green: Double(bg.g), blue: Double(bg.b), alpha: 1)
            if isStatic {
                // Freeze after the current frame: the last drawn frame
                // stays on screen, exactly like Folia's frozen u_time.
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

            // Advance shader time: full speed while playing, frozen
            // while static (the view is paused then, so this never
            // runs — the guard is here so a manual `draw()` cannot
            // lurch the stars).
            let now = CACurrentMediaTime()
            if let last = lastDrawTimestamp {
                let dt = min(max(now - last, 0), 0.1)
                if !isStatic {
                    time += Float(dt)
                }
            }
            lastDrawTimestamp = now

            var uniforms = SoraUniforms(
                primary: primaryColor,
                accent: accentColor,
                resolution: SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height)),
                time: time,
                pad: 0
            )
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SoraUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 150)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        // MARK: - Pipeline

        private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
            do {
                let library = try device.makeLibrary(source: soraShaderSource, options: nil)
                guard let vertex = library.makeFunction(name: "soraVertex"),
                      let fragment = library.makeFunction(name: "soraFragment")
                else { return nil }
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = vertex
                descriptor.fragmentFunction = fragment
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                // Pre-multiplied alpha, additive-ish over the solid
                // background clear colour.
                descriptor.colorAttachments[0].isBlendingEnabled = true
                descriptor.colorAttachments[0].rgbBlendOperation = .add
                descriptor.colorAttachments[0].alphaBlendOperation = .add
                descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
                descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
                descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
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

/// Must match the `SoraUniforms` struct in the shader below, field for
/// field and in order: two float4s, one float2, two floats — 48 bytes,
/// 16-byte aligned throughout.
private struct SoraUniforms {
    var primary: SIMD4<Float>
    var accent: SIMD4<Float>
    var resolution: SIMD2<Float>
    var time: Float
    var pad: Float
}

// MARK: - Shader

/// 150 stars as Metal points. Each star's speed (0.008–0.032), size,
/// position, wobble, blink rate, and accent membership come from a
/// hash of its vertex id, so the field is stable with no per-frame CPU
/// state. x drifts with time and wraps (`fract`); y wobbles gently
/// with a sine; blink runs 0.3–1.0. Point size is in drawable pixels
/// (the view renders at half point resolution). ~10% of stars take the
/// accent colour, the rest the primary colour.
private let soraShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct SoraUniforms {
    float4 primary;
    float4 accent;
    float2 resolution;
    float time;
    float pad;
};

struct SoraVSOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
    float alpha;
};

float soraHash(float n) {
    return fract(sin(n) * 43758.5453123);
}

vertex SoraVSOut soraVertex(uint vid [[vertex_id]], constant SoraUniforms &u [[buffer(0)]]) {
    float seed = float(vid);
    float hSpeed = soraHash(seed * 1.37 + 0.11);
    float hX = soraHash(seed * 2.71 + 0.53);
    float hY = soraHash(seed * 3.13 + 0.97);
    float hBlink = soraHash(seed * 4.79 + 0.31);
    float hSize = soraHash(seed * 5.83 + 0.71);
    float hAccent = soraHash(seed * 6.61 + 0.19);

    // Horizontal drift, wrapping at the edge; speed 0.008–0.032 in
    // units of screen widths per second.
    float speed = 0.008 + hSpeed * 0.024;
    float x = fract(hX + u.time * speed);
    // Gentle vertical wobble around the star's home row.
    float y = fract(hY + 0.02 * sin(u.time * 0.25 + seed));
    // Blink 0.3–1.0, each star on its own rate and phase.
    float blink = 0.3 + 0.7 * (0.5 + 0.5 * sin(u.time * (0.4 + hBlink * 1.2) + seed * 6.2831));
    // Point size in drawable pixels (half point resolution).
    float sizePx = 1.0 + hSize * 2.5;

    SoraVSOut out;
    out.position = float4(x * 2.0 - 1.0, 1.0 - y * 2.0, 0.0, 1.0);
    out.pointSize = sizePx;
    out.color = hAccent < 0.10 ? u.accent : u.primary;
    out.alpha = blink;
    return out;
}

fragment float4 soraFragment(SoraVSOut in [[stage_in]], float2 pointCoord [[point_coord]]) {
    // Soft round point: smoothstep falloff from the centre.
    float d = length(pointCoord - 0.5) * 2.0;
    float a = smoothstep(1.0, 0.15, d) * in.alpha;
    // Pre-multiplied alpha for the additive-ish blend.
    return float4(in.color.rgb * a, a);
}
"""

#endif
