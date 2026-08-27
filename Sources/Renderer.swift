import Metal
import QuartzCore
import CoreVideo
import simd

// Takes one frame of the screen, applies the shaders **in order**, and draws into the
// overlay layer. One of these per display.
//
// ── Why a chain ──────────────────────────────────────────────────────────
// Hyprland's decoration:screen_shader takes exactly one. So adding film grain to a CRT
// means merging two shaders into one file by hand, and the moment they are merged there
// is no switching one off or reordering them.
//
// Here we decide the compositing order, so there is no reason for that. Each pass draws
// offscreen and the next receives it as `tex` — from the shader's side, the fact that it
// receives one frame of the screen is unchanged. So a file placed in a chain behaves
// exactly as it does alone, and keeps running unchanged on Linux.
//
// The intermediate targets ping-pong between two textures. N of them would add 22MB per
// pass at 4K for nothing, and no pass ever looks two steps back, so two is enough.

// A byte-for-byte imitation of the UBO in ShaderSource.preamble.
//
// std140 is why this cannot be one Swift struct. Under those rules array elements are
// aligned to vec4 boundaries, so one element of a vec2[32] takes **16 bytes** rather than
// 8, and float[32] likewise. Swift's array of SIMD2<Float> packs at 8 bytes each, so
// handing it over as is reads values that drift from halfway on. Hence writing by float
// index — the offsets written here are the contract.
//
//   float[0..1]     screen_size
//   float[2..3]     pointer_position
//   float[4]        time
//   float[5..7]     (padding for the array's 16-byte alignment)
//   float[8  + i*4] pressed_positions[i].xy
//   float[136 + i*4] pressed_times[i]
//   float[264 + j]  knob j (promoted by --knobs, in the order the shader declared them)
//
// Knobs are floats, so their alignment is 4 — unlike arrays they do not widen to 16, and
// they pack one after another from 264. ShaderSource.preamble emits the fields in the
// same order.
struct GSGlobals {
    static let historyCount = 32
    static let positionsBase = 8
    static let timesBase = 8 + historyCount * 4
    static let knobsBase = timesBase + historyCount * 4   // 264

    private(set) var storage: [Float]

    init(knobCount: Int = 0) {
        storage = [Float](repeating: 0, count: GSGlobals.knobsBase + knobCount)
    }

    mutating func setKnobs(_ v: [Float]) {
        let n = Swift.min(v.count, storage.count - GSGlobals.knobsBase)
        guard n > 0 else { return }
        for i in 0..<n { storage[GSGlobals.knobsBase + i] = v[i] }
    }

    mutating func set(screenSize: SIMD2<Float>, pointer: SIMD2<Float>, time: Float) {
        storage[0] = screenSize.x; storage[1] = screenSize.y
        storage[2] = pointer.x;    storage[3] = pointer.y
        storage[4] = time
    }

    mutating func setHistory(_ clicks: [(pos: SIMD2<Float>, age: Float)]) {
        for i in 0..<GSGlobals.historyCount {
            let p = GSGlobals.positionsBase + i * 4
            let t = GSGlobals.timesBase + i * 4
            if i < clicks.count {
                storage[p] = clicks[i].pos.x
                storage[p + 1] = clicks[i].pos.y
                storage[t] = clicks[i].age
            } else {
                storage[p] = 0; storage[p + 1] = 0
                // Unused slots are dated far in the past. At 0 they would read as "just
                // clicked (0,0)" and ripples would keep bursting in the top-left corner.
                storage[t] = 1e6
            }
        }
    }
}

final class Renderer {

    // The vertex shader and the emergency passthrough. They enter the same pipeline as
    // the translated fragment, so the stage_in attribute number ([[user(locn0)]]) and the
    // binding numbers have to match what spirv-cross emits. Paired with binding 0/1 in
    // ShaderSource.
    private static let builtinMSL = """
    #include <metal_stdlib>
    using namespace metal;

    struct GSVertexOut {
        float4 position   [[position]];
        float2 v_texcoord [[user(locn0)]];
    };

    // One triangle covers the screen with no vertex buffer. vid 0,1,2 → uv (0,0) (2,0) (0,2).
    // v_texcoord has a top-left origin — the same coordinate system as a Hyprland screen
    // shader, so that comparing against pointer_position means what it means there.
    vertex GSVertexOut gs_vertex(uint vid [[vertex_id]]) {
        float2 uv = float2(float((vid << 1) & 2), float(vid & 2));
        GSVertexOut o;
        o.v_texcoord = uv;
        o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
        return o;
    }

    struct GSGlobalsMSL { float2 screen_size; float2 pointer_position; float time; };
    struct GSFragIn { float2 v_texcoord [[user(locn0)]]; };

    // What runs when no shader is attached or one failed to compile. The window covers
    // the whole screen, so without this escape hatch one typo in a shader is a black screen.
    fragment float4 gs_passthrough(GSFragIn in [[stage_in]],
                                   constant GSGlobalsMSL& g [[buffer(0)]],
                                   texture2d<float> tex [[texture(1)]],
                                   sampler smp [[sampler(1)]]) {
        return float4(tex.sample(smp, in.v_texcoord).rgb, 1.0);
    }

    // The marker for the feedback probe (--diag). Drawn **after** the real picture, inside
    // a scissor rect only. It is a pass of its own, independent of the shader, so it works
    // with any shader attached — feedback is a phenomenon of heavy shaders, and a probe
    // that only works with a passthrough would be useless.
    //
    // If our window is properly excluded from the capture, this magenta **never appears in
    // the next frame's capture.** If it appears, we are capturing ourselves.
    fragment float4 gs_solid() { return float4(1.0, 0.0, 1.0, 1.0); }
    """

    /// One slot of the chain. Holds the pipeline and that pass's own UBO — the knob count
    /// differs per pass, so the UBO's tail length does too.
    private struct Pass {
        let pipeline: MTLRenderPipelineState
        var globals: GSGlobals
    }

    /// One slot as handed in from outside. One sheet of MSL and the knob count it declares.
    struct PassSpec {
        let msl: String
        let knobCount: Int
        init(msl: String, knobCount: Int) { self.msl = msl; self.knobCount = knobCount }
    }

    let device: MTLDevice
    let layer: CAMetalLayer

    private let queue: MTLCommandQueue
    private let builtin: MTLLibrary
    private let sampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private let passthroughPipeline: MTLRenderPipelineState
    private var solid: MTLRenderPipelineState?
    /// Draws the diagnostic marker in the top-left (--diag).
    var drawsDiagMarker = false

    // ── Chain swaps happen on the render thread ──────────────────────────
    // setPasses is called on the main queue, render on the capture queue. Swapping an
    // array is not swapping a single reference — one side walking the array while the
    // other replaces it corrupts the Swift array's reference count and crashes.
    //
    // But the whole render does not go inside a lock. globals is written every frame, and
    // holding that under a lock would make the capture queue wait on the main queue.
    // Instead **only the handover** goes through the lock, and the actual swap is done by
    // the render thread itself at the head of a frame. That way live is always touched by
    // one thread.
    private let swap = NSLock()
    private var pending: [Pass]?
    private var pendingIsSet = false
    private var live: [Pass] = []

    /// Where knob values come from. Takes a pass number and returns that pass's values.
    /// Read every frame.
    var knobSource: ((Int) -> [Float])?

    /// The two intermediate targets. Reallocated when the screen size changes.
    private var pingpong: [MTLTexture] = []
    /// The UBO the passthrough uses. Making it fresh every frame would take 1KB from the
    /// heap per frame, so it is held. Like live, it belongs to the render thread.
    private var passthroughGlobals = GSGlobals()

    private let started = CACurrentMediaTime()

    /// Whether what is attached is the passthrough. Used in the status line. Main side only.
    private(set) var isPassthrough = true

    init?(device: MTLDevice, vsync: Bool = true) {
        guard let queue = device.makeCommandQueue(),
              let builtin = try? device.makeLibrary(source: Renderer.builtinMSL, options: nil)
        else { return nil }

        // clamp-to-edge because curvature reads outside [0,1]. Everything out there is
        // killed to black by the shader's bezel() anyway, but with repeat a line of the
        // opposite edge shows through before it dies.
        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }

        let l = CAMetalLayer()
        l.device = device
        // bgra8Unorm rather than sRGB matters. Under Hyprland this shader receives
        // gamma-encoded values as they are and does things like pow(col, CONTRAST). An
        // sRGB format here would deliver samples decoded to linear, and the same
        // expression would give a different picture. The capture side's colorSpaceName is
        // set to sRGB to match (Capture.swift), so values round-trip untouched.
        l.pixelFormat = .bgra8Unorm
        l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        l.framebufferOnly = true
        l.isOpaque = true
        l.maximumDrawableCount = 2   // 3 adds another frame of latency.
        // vsync off tears the screen but shows the shader's **real** cost. On, a heavy
        // shader and a light one both read as 60, and there is no telling whether a value
        // can go up or has to come down. For measurement only.
        l.displaySyncEnabled = vsync
        l.presentsWithTransaction = false

        self.device = device
        self.queue = queue
        self.builtin = builtin
        self.sampler = sampler
        self.layer = l

        guard let pass = Renderer.makePipeline(device: device, vertexLib: builtin,
                                               fragmentLib: builtin, fragmentName: "gs_passthrough")
        else { return nil }
        self.passthroughPipeline = pass
        self.solid = Renderer.makePipeline(device: device, vertexLib: builtin,
                                           fragmentLib: builtin, fragmentName: "gs_solid")

        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        if textureCache == nil { return nil }
    }

    private static func makePipeline(device: MTLDevice, vertexLib: MTLLibrary,
                                     fragmentLib: MTLLibrary, fragmentName: String)
        -> MTLRenderPipelineState?
    {
        guard let vf = vertexLib.makeFunction(name: "gs_vertex"),
              let ff = fragmentLib.makeFunction(name: fragmentName) else { return nil }
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = vf
        d.fragmentFunction = ff
        d.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    /// Swap in a whole chain. Throws on failure and **leaves what is attached alone** — a
    /// screen that goes dark because the file being edited is momentarily not valid syntax
    /// cannot be fixed.
    ///
    /// One failure partway does not attach the preceding slots either. A chain only means
    /// something whole — a screen quietly missing the grain that came after the CRT is
    /// harder to notice than a screen that did not change. Everything is built, then
    /// swapped at once.
    func setPasses(_ specs: [PassSpec]) throws {
        var built: [Pass] = []
        built.reserveCapacity(specs.count)
        for (i, spec) in specs.enumerated() {
            do {
                let lib = try device.makeLibrary(source: spec.msl, options: nil)
                // spirv-cross renames GLSL's main to main0 on the way out.
                guard let p = Renderer.makePipeline(device: device, vertexLib: builtin,
                                                    fragmentLib: lib, fragmentName: "main0")
                else {
                    throw ShaderError.compile(stage: Str.renderer_stage_pipeline,
                                              log: Str.renderer_err_noPipeline)
                }
                built.append(Pass(pipeline: p, globals: GSGlobals(knobCount: spec.knobCount)))
            } catch {
                // Say which slot it came from. In a long chain this one phrase stands in
                // for the file name.
                throw ShaderError.compile(stage: Str.renderer_stage_chainPass(i + 1),
                                          log: "\(error)")
            }
        }
        handOver(built)
        isPassthrough = built.isEmpty
    }

    func usePassthrough() {
        handOver([])
        isPassthrough = true
    }

    private func handOver(_ passes: [Pass]) {
        swap.lock()
        pending = passes
        pendingIsSet = true
        swap.unlock()
    }

    /// Allocates the intermediate targets to the screen size. Only when needed — with a
    /// single-slot chain it goes from capture straight to drawable, so neither is allocated.
    private func ensurePingpong(width w: Int, height h: Int, needed: Int) {
        if needed == 0 {
            if !pingpong.isEmpty { pingpong = [] }
            return
        }
        if pingpong.count == needed,
           pingpong[0].width == w, pingpong[0].height == h { return }

        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        // Only the GPU ever sees these, so private. shared here would open the door to
        // 22MB moving to the CPU side every frame.
        d.storageMode = .private
        var made: [MTLTexture] = []
        for _ in 0..<needed {
            guard let t = device.makeTexture(descriptor: d) else { pingpong = []; return }
            made.append(t)
        }
        pingpong = made
    }

    /// Every time capture hands over a frame. Called on the capture queue.
    func render(_ pixelBuffer: CVPixelBuffer, pointer: SIMD2<Float>,
                clicks: [(pos: SIMD2<Float>, age: Float)]) {
        // The chain swap happens here, at the head of a frame. Below this point live is
        // touched by this thread alone (see the note at its declaration).
        swap.lock()
        if pendingIsSet { live = pending ?? []; pending = nil; pendingIsSet = false }
        swap.unlock()

        guard let cache = textureCache else { return }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w > 0, h > 0 else { return }

        var cvTex: CVMetalTexture?
        let ok = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex)
        guard ok == kCVReturnSuccess, let cvTex,
              let captured = CVMetalTextureGetTexture(cvTex) else { return }

        // Match the drawable to the capture size. A resolution change is followed next frame.
        if layer.drawableSize.width != CGFloat(w) || layer.drawableSize.height != CGFloat(h) {
            layer.drawableSize = CGSize(width: w, height: h)
        }
        guard let drawable = layer.nextDrawable() else { return }
        guard let cb = queue.makeCommandBuffer() else { return }

        let now = Float(CACurrentMediaTime() - started)
        let size = SIMD2(Float(w), Float(h))
        let count = live.count
        ensurePingpong(width: w, height: h, needed: count > 1 ? 2 : 0)
        // If the intermediate targets could not be allocated (effectively, out of memory),
        // only the first slot runs. A less shaded screen beats a black one.
        let chained = count > 1 && pingpong.count == 2

        /// Draws one slot: reads src, writes dst.
        func encode(_ pass: MTLRenderPipelineState, globals: inout GSGlobals,
                    src: MTLTexture, dst: MTLTexture, last: Bool) {
            let d = MTLRenderPassDescriptor()
            d.colorAttachments[0].texture = dst
            d.colorAttachments[0].loadAction = .dontCare
            d.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: d) else { return }
            enc.setRenderPipelineState(pass)
            globals.storage.withUnsafeBytes {
                enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
            }
            enc.setFragmentTexture(src, index: 1)
            enc.setFragmentSamplerState(sampler, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            if last, drawsDiagMarker, let solid {
                // The scissor has a top-left origin, the same direction as texture
                // coordinates. The marker always goes on **the last** slot — it has to be
                // in the picture that actually reaches the screen for reading it back out
                // of the capture to mean anything.
                enc.setScissorRect(MTLScissorRect(x: 0, y: 0,
                                                  width: min(64, w), height: min(64, h)))
                enc.setRenderPipelineState(solid)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
            enc.endEncoding()
        }

        if count == 0 {
            passthroughGlobals.set(screenSize: size, pointer: pointer, time: now)
            encode(passthroughPipeline, globals: &passthroughGlobals,
                   src: captured, dst: drawable.texture, last: true)
        } else {
            var src = captured
            for i in 0..<count {
                live[i].globals.set(screenSize: size, pointer: pointer, time: now)
                live[i].globals.setHistory(clicks)
                if let knobSource { live[i].globals.setKnobs(knobSource(i)) }

                // Only the last slot draws into the drawable. Everything before it passes
                // through the ping-pong — even i writes [0], odd writes [1], so the place
                // being read and the place being written are never the same.
                let isLast = (i == count - 1) || !chained
                let dst = isLast ? drawable.texture : pingpong[i % 2]
                encode(live[i].pipeline, globals: &live[i].globals,
                       src: src, dst: dst, last: isLast)
                if isLast { break }
                src = dst
            }
        }

        cb.present(drawable)
        cb.commit()
        // waitUntilCompleted is not called. The IOSurface is held for as long as the
        // CVMetalTexture is alive, and the capture side's queueDepth prevents reuse.
    }
}
