//
//  MRRenderer.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 6/17/23.
//

import Metal
import MetalFX
import func QuartzCore.CACurrentMediaTime
import class QuartzCore.CAMetalLayer
import struct simd.simd_float3x3
import func simd.distance_squared

// Partially sourced from:
// https://developer.apple.com/documentation/metalfx/applying_temporal_antialiasing_and_upscaling_using_metalfx

// TODO: Multiple rendering modes.
// - Interactive: accounts for latency, synchronized with display
// - Hybrid: writes a saveable frame, and the recording can be started/stopped
// - Headless: removes stutters, suitable for production

// TODO: Options for storing recorded frames.
// - Async handler: pointer in memory
// - File: uses built-in image/video encoder, stores to a pre-defined URL

@_alignment(16)
struct Arguments {
  var fovMultiplier: Float
  var positionX: Float
  var positionY: Float
  var positionZ: Float
  var rotation: simd_float3x3
  var jitter: SIMD2<Float>
  var frameSeed: UInt32
  var numLights: UInt16
  
  var minSamples: Float16
  var maxSamples: Float16
  var qualityCoefficient: Float16
  
  var maxRayHitTime: Float
  var exponentialFalloffDecayConstant: Float
  var minimumAmbientIllumination: Float
  var diffuseReflectanceScale: Float
  
  var gridWidth: UInt16
}

// Track when to reset the MetalFX upscaler.
struct ResetTracker {
  var currentFrameID: Int = -1
  var resetUpscaler: Bool = false
  
  mutating func update(time: MRTimeContext) {
    let nextFrameID = time.absolute.frames
    if nextFrameID == 0 && nextFrameID != currentFrameID {
      resetUpscaler = true
    } else {
      resetUpscaler = false
    }
    currentFrameID = nextFrameID
  }
}

public class MRRenderer {
  var upscaledSize: SIMD2<Int>
  var intermediateSize: SIMD2<Int>
  var jitterFrameID: Int = 0
  var jitterOffsets: SIMD2<Float> = .zero
  var textureIndex: Int = 0
  
  // The time of this frame.
  var time: MRTimeContext!
  var renderIndex: Int = 0
  var tracker: ResetTracker = .init()
  
  // Main rendering resources.
  var device: MTLDevice
  var commandQueue: MTLCommandQueue
  var accelBuilder: MRAccelBuilder!
  
  // TODO: Create several ray tracing pipelines, one for each cell size.
  var rayTracingPipeline: MTLComputePipelineState!
  var upscaler: MTLFXTemporalScaler!
  
  struct IntermediateTextures {
    var color: MTLTexture
    var depth: MTLTexture
    var motion: MTLTexture
    
    // Metal is forcing me to make another texture for this, because the
    // drawable texture "must have private storage mode".
    var upscaled: MTLTexture
  }
  
  // Double-buffer the textures to remove dependencies between frames.
  var textures: [IntermediateTextures] = []
  var currentTextures: IntermediateTextures {
    self.textures[jitterFrameID % 2]
  }
  
  // Cache previous arguments to generate motion vectors.
  var previousArguments: Arguments?
  var currentArguments: Arguments?
  var lights: [MRLight] = []
  var lightsBuffer: MTLBuffer
  
  // Enter the width and height of the texture to present, not the resolution
  // you expect the internal GPU shader to write to.
  public init(
    metallibURL: URL,
    width: Int,
    height: Int
  ) {
    // Initialize Metal resources.
    self.device = MTLCreateSystemDefaultDevice()!
    self.commandQueue = device.makeCommandQueue()!
    
    guard width % 2 == 0, height % 2 == 0 else {
      fatalError("MRRenderer only accepts even image sizes.")
    }
    self.upscaledSize = SIMD2(width, height)
    self.intermediateSize = SIMD2(width / 2, height / 2)
    
    // Ensure the textures use lossless compression.
    let commandBuffer = commandQueue.makeCommandBuffer()!
    let encoder = commandBuffer.makeBlitCommandEncoder()!
    
    for _ in 0..<2 {
      let desc = MTLTextureDescriptor()
      desc.width = intermediateSize.x
      desc.height = intermediateSize.y
      desc.storageMode = .private
      desc.usage = [ .shaderWrite, .shaderRead ]
      
      desc.pixelFormat = .rgb10a2Unorm
      let color = device.makeTexture(descriptor: desc)!
      color.label = "Intermediate Color"
      
      desc.pixelFormat = .r32Float
      let depth = device.makeTexture(descriptor: desc)!
      depth.label = "Intermediate Depth"
      
      desc.pixelFormat = .rg16Float
      let motion = device.makeTexture(descriptor: desc)!
      motion.label = "Intermediate Motion"
      
      desc.pixelFormat = .rgb10a2Unorm
      desc.width = upscaledSize.x
      desc.height = upscaledSize.y
      let upscaled = device.makeTexture(descriptor: desc)!
      upscaled.label = "Upscaled Color"
      
      textures.append(IntermediateTextures(
        color: color, depth: depth, motion: motion, upscaled: upscaled))
      
      for texture in [color, depth, motion, upscaled] {
        encoder.optimizeContentsForGPUAccess(texture: texture)
      }
    }
    encoder.endEncoding()
    commandBuffer.commit()
    
    let lightsBufferLength = 3 * 8 * MemoryLayout<MRLight>.stride
    precondition(MemoryLayout<MRLight>.stride == 16)
    self.lightsBuffer = device.makeBuffer(length: lightsBufferLength)!
    
    let library = try! device.makeLibrary(URL: metallibURL)
    self.accelBuilder = MRAccelBuilder(renderer: self, library: library)
    self.initRayTracingPipeline(library: library)
    self.initUpscaler()
  }
  
  func initRayTracingPipeline(library: MTLLibrary) {
    // Initialize resolution and aspect ratio for rendering.
    let constants = MTLFunctionConstantValues()
    
    // Actual texture width.
    var screenWidth: UInt32 = .init(intermediateSize.x)
    constants.setConstantValue(&screenWidth, type: .uint, index: 0)
    
    // Actual texture height.
    var screenHeight: UInt32 = .init(intermediateSize.y)
    constants.setConstantValue(&screenHeight, type: .uint, index: 1)
    
    var suppressSpecular: Bool = false
    constants.setConstantValue(&suppressSpecular, type: .bool, index: 2)
    
    // Initialize the compute pipeline.
    let function = try! library.makeFunction(
      name: "renderMain", constantValues: constants)
    let desc = MTLComputePipelineDescriptor()
    desc.computeFunction = function
    self.rayTracingPipeline = try! device
      .makeComputePipelineState(descriptor: desc, options: [], reflection: nil)
  }
  
  func initUpscaler() {
    let desc = MTLFXTemporalScalerDescriptor()
    desc.inputWidth = intermediateSize.x
    desc.inputHeight = intermediateSize.y
    desc.outputWidth = upscaledSize.x
    desc.outputHeight = upscaledSize.y
    desc.colorTextureFormat = textures[0].color.pixelFormat
    desc.depthTextureFormat = textures[0].depth.pixelFormat
    desc.motionTextureFormat = textures[0].motion.pixelFormat
    desc.outputTextureFormat = desc.colorTextureFormat
    
    desc.isAutoExposureEnabled = false
    desc.isInputContentPropertiesEnabled = false
    desc.inputContentMinScale = 2
    desc.inputContentMaxScale = 2
    
    guard let upscaler = desc.makeTemporalScaler(device: device) else {
      fatalError("The temporal scaler effect is not usable!")
    }
    self.upscaler = upscaler
    
    // We already store motion vectors in units of pixels. The default value
    // multiplies the vector by 'intermediateSize', which we don't want.
    upscaler.motionVectorScaleX = 1
    upscaler.motionVectorScaleY = 1
    upscaler.isDepthReversed = true
  }
}

extension MRRenderer {
  // Perform any updating work that happens before encoding the rendering work.
  // This should be called as early as possible each frame, to hide any latency
  // between now and when it can encode the rendering work.
  private func updateResources() {
    self.jitterFrameID += 1
    self.jitterOffsets = makeJitterOffsets()
    self.textureIndex = (self.textureIndex + 1) % 2
    self.renderIndex = (self.renderIndex + 1) % 3
  }
  
  private func makeJitterOffsets() -> SIMD2<Float> {
    func halton(index: UInt32, base: UInt32) -> Float {
      var result: Float = 0.0
      var fractional: Float = 1.0
      var currentIndex: UInt32 = index
      while currentIndex > 0 {
        fractional /= Float(base)
        result += fractional * Float(currentIndex % base)
        currentIndex /= base
      }
      return result
    }
    
    // The sample uses a Halton sequence rather than purely random numbers to
    // generate the sample positions to ensure good pixel coverage. This has the
    // result of sampling a different point within each pixel every frame.
    let jitterIndex = UInt32(self.jitterFrameID % 32 + 1)
    
    // Return Halton samples (+/- 0.5, +/- 0.5) that represent offsets of up to
    // half a pixel.
    let x = halton(index: jitterIndex, base: 2) - 0.5
    let y = halton(index: jitterIndex, base: 3) - 0.5
    
    // We're not sampling textures or working with multiple coordinate spaces.
    // No need to flip the Y coordinate to match another coordinate space.
    return SIMD2(x, y)
  }
  
  private func upscale(
    commandBuffer: MTLCommandBuffer,
    drawableTexture: MTLTexture
  ) {
    tracker.update(time: time)
    
    // Bind the intermediate textures.
    let currentTextures = self.currentTextures
    upscaler.reset = tracker.resetUpscaler
    upscaler.colorTexture = currentTextures.color
    upscaler.depthTexture = currentTextures.depth
    upscaler.motionTexture = currentTextures.motion
    upscaler.outputTexture = currentTextures.upscaled
    upscaler.jitterOffsetX = -self.jitterOffsets.x
    upscaler.jitterOffsetY = -self.jitterOffsets.y
    upscaler.encode(commandBuffer: commandBuffer)
    
    // Metal is forcing me to copy the upscaled texture to the drawable.
    let blitEncoder = commandBuffer.makeBlitCommandEncoder()!
    blitEncoder.copy(from: currentTextures.upscaled, to: drawableTexture)
    blitEncoder.endEncoding()
  }
}

extension MRRenderer {
  // TODO: Integrate with modern graphics APIs' asynchronous SSD loading. Allow
  // computationally demanding simulations to run ahead-of-time.
  //
  // If you're rendering from a dynamic scene, there is a different API with a
  // different C function. The dynamic API should be used when loading geometry
  // is resource-intensive or high-latency and therefore requires Metal IO
  // command buffers. Otherwise, the static API is sufficient to render dynamic
  // geometry.
  public func setGeometry(
    // TODO: Consider removing the dependency on frame rate. Do this by making
    // frame rate an input argument to initialize an MRTimeContext.
    time: MRTimeContext,
    atomProvider: inout MRAtomProvider,
    styleProvider: MRAtomStyleProvider
  ) {
    var atoms = atomProvider.atoms(time: time)
    let styles = styleProvider.styles
    let available = styleProvider.available
    
    for i in atoms.indices {
      let element = Int(atoms[i].element)
      if available[element] {
        let radius = styles[element].radius
        atoms[i].radiusSquared = radius * radius
        atoms[i].flags = 0
      } else {
        let radius = styles[0].radius
        atoms[i].element = 0
        atoms[i].radiusSquared = radius * radius
        atoms[i].flags = 0x1 | 0x2
      }
    }
    
    self.time = time
    self.accelBuilder.atoms = atoms
    self.accelBuilder.styles = styles
  }
  
  // Only call this once per frame.
  // - lightPower: Intensity of the camera-centered light for Blinn-Phong shading.
  public func setCamera(
    fovDegrees: Float,
    position: SIMD3<Float>,
    rotation: simd_float3x3,
    lights: [MRLight],
    quality: MRQuality
  ) {
    self.previousArguments = currentArguments
    
    let maxRayHitTime: Float = 1.0 // range(0...100, 0.2)
    let minimumAmbientIllumination: Float = 0.07 // range(0...1, 0.01)
    let diffuseReflectanceScale: Float = 0.5 // range(0...1, 0.1)
    let decayConstant: Float = 2.0 // range(0...20, 0.25)
    
    precondition(lights.count < UInt16.max, "Too many lights.")
    
    var totalDiffuse: Float = 0
    var totalSpecular: Float = 0
    for light in lights {
      totalDiffuse += Float(light.diffusePower)
      totalSpecular += Float(light.specularPower)
    }
    self.lights = (lights.map { _light in
      var light = _light
      
      // Normalize so nothing causes oversaturation.
      let diffuse = Float(light.diffusePower) / totalDiffuse
      let specular = Float(light.specularPower) / totalSpecular
      light.diffusePower = Float16(diffuse)
      light.specularPower = Float16(specular)
      light.resetMask()
      
      // Mark camera-centered lights as something to render more efficiently.
      if sqrt(distance_squared(light.origin, position)) < 1e-3 {
        #if arch(arm64)
        var diffuseMask = light.diffusePower.bitPattern
        diffuseMask |= 0x1
        light.diffusePower = Float16(bitPattern: diffuseMask)
        #endif
      }
      return light
    })
    
    // Quality coefficients are calibrated against 640x640 -> 1280x1280 resolution.
    var screenMagnitude = Float(upscaledSize.x * upscaledSize.y)
    screenMagnitude = sqrt(screenMagnitude) / 1280
    let qualityCoefficient = quality.qualityCoefficient * screenMagnitude
    
    self.currentArguments = Arguments(
      fovMultiplier: self.fovMultiplier(fovDegrees: fovDegrees),
      positionX: position.x,
      positionY: position.y,
      positionZ: position.z,
      rotation: rotation,
      jitter: jitterOffsets,
      frameSeed: UInt32.random(in: 0...UInt32.max),
      numLights: UInt16(lights.count),
      
      minSamples: Float16(quality.minSamples),
      maxSamples: Float16(quality.maxSamples),
      qualityCoefficient: Float16(qualityCoefficient),
      
      maxRayHitTime: maxRayHitTime,
      exponentialFalloffDecayConstant: decayConstant,
      minimumAmbientIllumination: minimumAmbientIllumination,
      diffuseReflectanceScale: diffuseReflectanceScale,
    
      gridWidth: 0)
    
    let desiredSize = 3 * lights.count * MemoryLayout<MRLight>.stride
    if lightsBuffer.length < desiredSize {
      var newLength = lightsBuffer.length
      while newLength < desiredSize {
        newLength = newLength << 1
      }
      lightsBuffer = device.makeBuffer(length: newLength)!
    }
  }
  
  private func fovMultiplier(fovDegrees: Float) -> Float {
    // NOTE: This currently assumes the image is square. We eventually need to
    // support rectangular image sizes for e.g. 1920x1080 video.
    
    // How many pixels exist in either direction.
    let fov90Span = 0.5 * Float(intermediateSize.x)
    
    // Larger FOV means the same ray will reach an angle farther away from the
    // center. 1 / fovSpan is larger, so fovSpan is smaller. The difference
    // should be the ratio between the tangents of the two half-angles. And
    // one side of the ratio is tan(90 / 2) = 1.0.
    let fovRadians: Float = fovDegrees * .pi / 180
    let halfAngleTangent = tan(fovRadians / 2)
    let halfAngleTangentRatio = halfAngleTangent / 1.0
    
    // Let A = fov90Span
    // Let B = pixels covered by the 45° boundary in either direction.
    // Ray = ((pixelsRight, pixelsUp) * fovMultiplier, -1)
    //
    // FOV / 2 < 45°
    // - edge of image is ray (<1, <1, -1)
    // - A = 100 pixels
    // - B = 120 pixels (off-screen)
    // - fovMultiplier = 1 / 120 = 1 / B
    // FOV / 2 = 45°
    // - edge of image is ray (1, 1, -1)
    // - fovMultiplier = unable to determine
    // FOV / 2 > 45°
    // - edge of image is ray (>1, >1, -1)
    // - A = 100 pixels
    // - B = 80 pixels (well within screen bounds)
    // - fovMultiplier = 1 / 80 = 1 / B
    
    // Next: what is B as a function of fov90Span and halfAngleTangentRatio?
    // FOV / 2 < 45°
    // - A = 100 pixels
    // - B = 120 pixels (off-screen)
    // - halfAngleTangentRatio = 0.8
    // - formula: B = A / halfAngleTangentRatio
    // FOV / 2 = 45°
    // - A = 100 pixels
    // - B = 100 pixels
    // - formula: cannot be determined
    // FOV / 2 > 45°
    // - edge of image is ray (>1, >1, -1)
    // - A = 100 pixels
    // - B = 80 pixels (well within screen bounds)
    // - halfAngleTangentRatio = 1.2
    // - formula: B = A / halfAngleTangentRatio
    //
    // fovMultiplier = 1 / B = 1 / (A / halfAngleTangentRatio)
    // fovMultiplier = halfAngleTangentRatio / fov90Span
    return halfAngleTangentRatio / fov90Span
  }
}

extension MRRenderer {
  // Eventually, we will allow presenting to a raw C pointer, instead of to a
  // display drawable. This option will require a callback, which is called
  // after the output's memory is written to.
  public func render(
    layer: CAMetalLayer,
    handler: @escaping MTLCommandBufferHandler
  ) {
    defer {
      // Invalidate the time.
      self.time = nil
    }
    self.updateResources()
    self.accelBuilder.updateResources()
    
    // Command buffer shared between the geometry and rendering passes.
    var commandBuffer = commandQueue.makeCommandBuffer()!
    
    // Encode the geometry data.
    let encoder = commandBuffer.makeComputeCommandEncoder()!
    accelBuilder.buildDenseGrid(encoder: encoder)
    
    encoder.setComputePipelineState(rayTracingPipeline)
    accelBuilder.encodeGridArguments(encoder: encoder)
    accelBuilder.setGridWidth(arguments: &currentArguments!)
    
    // Encode the arguments.
    let tempAllocation = malloc(256)!
    if previousArguments == nil {
      previousArguments = currentArguments
    }
    let stride = MemoryLayout<Arguments>.stride
    precondition(stride <= 128)
    memcpy(tempAllocation, &currentArguments!, stride)
    memcpy(tempAllocation + 128, &previousArguments!, stride)
    encoder.setBytes(tempAllocation, length: 256, index: 0)
    free(tempAllocation)
    
    accelBuilder.styles.withUnsafeBufferPointer {
      let length = $0.count * MemoryLayout<MRAtomStyle>.stride
      encoder.setBytes($0.baseAddress!, length: length, index: 1)
    }
    
    // Encode the lights.
    let lightsBufferOffset = renderIndex * (lightsBuffer.length / 3)
    let lightsRawPointer = lightsBuffer.contents() + lightsBufferOffset
    let lightsPointer = lightsRawPointer.assumingMemoryBound(to: MRLight.self)
    for i in 0..<lights.count {
      lightsPointer[i] = lights[i]
    }
    encoder.setBuffer(lightsBuffer, offset: lightsBufferOffset, index: 2)
    
    // Encode the output textures.
    let textures = self.currentTextures
    encoder.setTextures(
      [textures.color, textures.depth, textures.motion], range: 0..<3)
    
    // Dispatch an even number of threads (the shader will rearrange them).
    let numThreadgroupsX = (intermediateSize.x + 7) / 8
    let numThreadgroupsY = (intermediateSize.y + 7) / 8
    encoder.dispatchThreadgroups(
      MTLSizeMake(numThreadgroupsX, numThreadgroupsY, 1),
      threadsPerThreadgroup: MTLSizeMake(8, 8, 1))
    encoder.endEncoding()
    
    if accelBuilder.profileThisFrame {
      accelBuilder.addSamplingHandler(commandBuffer: commandBuffer)
      commandBuffer.commit()
      commandBuffer = commandQueue.makeCommandBuffer()!
    }
    
    // Acquire a reference to the drawable.
    let drawable = layer.nextDrawable()!
    precondition(drawable.texture.width == upscaledSize.x)
    precondition(drawable.texture.height == upscaledSize.y)
    
    // Encode the upscaling pass.
    upscale(commandBuffer: commandBuffer, drawableTexture: drawable.texture)
    
    // Present the drawable and signal the semaphore.
    commandBuffer.present(drawable)
    commandBuffer.addCompletedHandler(handler)
    commandBuffer.commit()
  }
}
