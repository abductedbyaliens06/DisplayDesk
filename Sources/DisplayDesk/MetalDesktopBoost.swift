import AppKit
import CoreMedia
import MetalKit
import ScreenCaptureKit

private final class CaptureFrame: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// A local, explicitly permitted fallback for systems that clamp gamma tables.
/// The stream excludes its own output window to prevent capture feedback.
@MainActor
final class MetalDesktopBoost: NSObject, SCStreamOutput, SCStreamDelegate, MTKViewDelegate {
    private let window: NSWindow
    private let view: MTKView
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let screenFrame: NSRect
    private var cache: CVMetalTextureCache?
    private var stream: SCStream?
    private var frame: CaptureFrame?
    private(set) var failed = false
    private(set) var receivedFrame = false
    var factor: Double = 1 { didSet { if receivedFrame { view.draw() } } }

    init(screen: NSScreen) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw DisplayControlError.unavailable("Metal rendering is unavailable.")
        }
        self.queue = queue
        screenFrame = screen.frame
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex desktopVertex(uint index [[vertex_id]]) {
            float2 positions[3] = {float2(-1,-1),float2(3,-1),float2(-1,3)};
            Vertex v; v.position = float4(positions[index],0,1);
            v.uv = float2((positions[index].x+1)*0.5, 1-(positions[index].y+1)*0.5); return v;
        }
        fragment float4 desktopFragment(Vertex v [[stage_in]], texture2d<float> image [[texture(0)]], constant float &boost [[buffer(0)]]) {
            constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
            float4 c = image.sample(s, v.uv);
            return float4(c.rgb * boost, 1.0);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "desktopVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "desktopFragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: device)
        view.colorPixelFormat = .rgba16Float; view.framebufferOnly = true
        view.isPaused = true; view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
        window = NSWindow(contentRect: NSRect(origin: screen.frame.origin, size: CGSize(width: 1, height: 1)), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.backgroundColor = .clear; window.isOpaque = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.contentView = view
        super.init()
        view.delegate = self
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess else {
            throw DisplayControlError.unavailable("Could not create the desktop texture cache.")
        }
    }
    func start(displayID: CGDirectDisplayID, excludedWindowIDs: Set<CGWindowID>) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw DisplayControlError.unavailable("Metal boost needs Screen Recording permission for Display Desk. Use Allow Screen Recording, then enable it in System Settings and restart the app if requested.")
        }
        window.orderFrontRegardless()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw DisplayControlError.unavailable("The selected display is no longer available to capture.")
        }
        // Refuse to start unless the output window can be explicitly excluded.
        let excluded = content.windows.filter { excludedWindowIDs.contains($0.windowID) || $0.windowID == CGWindowID(window.windowNumber) }
        guard excluded.contains(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw DisplayControlError.unavailable("Could not exclude the boost window from capture. Metal boost was not started.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width; configuration.height = display.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.captureDynamicRange = .SDR
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.captureMicrophone = false
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "DisplayDesk.localDesktopFrames"))
        self.stream = stream
        try await stream.startCapture()
        // Do not cover the screen until a real desktop frame has rendered.
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if receivedFrame { return }
            if failed { break }
        }
        close()
        throw DisplayControlError.unavailable("No desktop frame arrived for Metal boost. The overlay was removed.")
    }
    var windowID: CGWindowID { CGWindowID(window.windowNumber) }
    func matches(screen: NSScreen?) -> Bool { screen?.frame == screenFrame }
    func close() {
        window.orderOut(nil); window.close()
        view.delegate = nil; frame = nil
        stream?.stopCapture(completionHandler: { _ in }); stream = nil
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let buffer = sampleBuffer.imageBuffer else { return }
        if let metadata = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
           let raw = metadata.first?[.status] as? Int, raw != SCFrameStatus.complete.rawValue { return }
        let packet = CaptureFrame(buffer)
        Task { @MainActor [weak self] in
            guard let self, self.stream != nil else { return }
            self.frame = packet
            self.view.draw()
        }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor [weak self] in self?.failed = true; self?.close() }
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let frame, let cache, let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor, let command = queue.makeCommandBuffer() else { return }
        var texture: CVMetalTexture?
        let buffer = frame.buffer
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, .bgra8Unorm_srgb,
            CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &texture) == kCVReturnSuccess,
              let texture, let image = CVMetalTextureGetTexture(texture), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(image, index: 0)
        var gain = Float(factor)
        encoder.setFragmentBytes(&gain, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // Keep the captured IOSurface alive until its GPU read has finished.
        let retainedFrame = frame
        command.addCompletedHandler { _ in _ = retainedFrame }
        command.present(drawable); command.commit()
        if !receivedFrame { receivedFrame = true; window.setFrame(screenFrame, display: true); window.orderFrontRegardless() }
    }
}
