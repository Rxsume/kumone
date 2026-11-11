import Foundation
import Metal
import Testing

@testable import KumoneCore

/// The latent and sora background shaders are compiled at runtime from
/// source strings, so compiling the Swift target never proves they
/// compile: the latent shader once shipped a GLSL `mod()` call Metal
/// rejects, and the player page silently fell back to its clear colour
/// with no error anywhere. These tests compile the exact shipped
/// sources with a real Metal device, so a future shader breakage fails
/// CI instead of shipping flat. Each test only compiles a source
/// string — no shared state — so parallel execution is safe.
@Suite struct LatentShaderCompilationTests {

    @Test func latentShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            try Test.skip("No Metal device in this environment; nothing to compile against.")
        }
        let library = try device.makeLibrary(source: latentShaderSource, options: nil)
        #expect(library.makeFunction(name: "latentVertex") != nil)
        #expect(library.makeFunction(name: "latentFragment") != nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "latentVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "latentFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @Test func soraShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            try Test.skip("No Metal device in this environment; nothing to compile against.")
        }
        let library = try device.makeLibrary(source: soraShaderSource, options: nil)
        #expect(library.makeFunction(name: "soraVertex") != nil)
        #expect(library.makeFunction(name: "soraFragment") != nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "soraVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "soraFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        _ = try device.makeRenderPipelineState(descriptor: descriptor)
    }
}
