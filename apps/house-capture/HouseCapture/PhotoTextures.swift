import Foundation
import ImageIO
import SceneKit
import simd

/// Photo pixels mapped onto triangles, independent of the density of the LiDAR vertices.
/// Each source is cropped to the part actually used and all decoded textures share a pixel budget.
/// The camera picks its own exposure for every photo, so each one is levelled before it's used: to
/// `consensus` (the scan's average color per vertex) where it's given, else by its recorded exposure.
struct PhotoTextures {
  var inside: SCNGeometry?
  var outside: SCNGeometry?
  var insideFallback: [UInt32]
  var outsideFallback: [UInt32]
  var photoCount: Int
  var triangleCount: Int
  var pixelCount: Int

  private struct Patch {
    let photo: PreviewPhoto
    let worldToCamera: simd_float4x4
    var inside: [UInt32] = []
    var outside: [UInt32] = []
    var lo = SIMD2<Float>(repeating: .infinity)
    var hi = SIMD2<Float>(repeating: -.infinity)

    func project(_ point: SIMD3<Float>) -> SIMD2<Float> {
      let p = worldToCamera * SIMD4(point, 1)
      return SIMD2(photo.fx * p.x / -p.z + photo.cx, -photo.fy * p.y / -p.z + photo.cy)
    }
    var crop: CGRect {
      let x = max(0, floor(lo.x) - 3), y = max(0, floor(lo.y) - 3)
      let right = min(Float(photo.width), ceil(hi.x) + 3), bottom = min(Float(photo.height), ceil(hi.y) + 3)
      return CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(right - x), height: CGFloat(bottom - y))
    }
  }

  static func build(mesh: PLYMesh, inside: [UInt32], outside: [UInt32], photos: [PreviewPhoto], consensus: [UInt8]? = nil,
                    pixelBudget: Int, progress: (Double) -> Void, isCancelled: () -> Bool) -> PhotoTextures? {
    let triangles = inside + outside
    guard !triangles.isEmpty, !photos.isEmpty,
          let winners = VertexColorBaker.assignPhotos(mesh: mesh, triangles: triangles, photos: photos,
                                                      progress: { progress($0 * 0.7) }, isCancelled: isCancelled) else { return nil }
    var patches = photos.map { Patch(photo: $0, worldToCamera: $0.cameraToHouse.inverse) }
    var result = PhotoTextures(insideFallback: [], outsideFallback: [], photoCount: 0, triangleCount: 0, pixelCount: 0)
    for (face, winner) in winners.enumerated() {
      let offset = face * 3
      let ids = triangles[offset..<offset + 3]
      if winner < 0 {
        if offset < inside.count { result.insideFallback.append(contentsOf: ids) }
        else { result.outsideFallback.append(contentsOf: ids) }
        continue
      }
      let index = Int(winner)
      if offset < inside.count { patches[index].inside.append(contentsOf: ids) }
      else { patches[index].outside.append(contentsOf: ids) }
      for id in ids {
        let uv = patches[index].project(mesh.position(Int(id)))
        patches[index].lo = simd_min(patches[index].lo, uv)
        patches[index].hi = simd_max(patches[index].hi, uv)
      }
    }
    patches.removeAll { $0.inside.isEmpty && $0.outside.isEmpty }
    let area = patches.reduce(0.0) { $0 + $1.crop.width * $1.crop.height }
    let scale = min(1, sqrt(Double(pixelBudget) / max(1, area)))
    var positions: [Float] = [], normals: [Float] = [], texcoords: [Float] = []
    var insideElements: [SCNGeometryElement] = [], outsideElements: [SCNGeometryElement] = []
    var insideMaterials: [SCNMaterial] = [], outsideMaterials: [SCNMaterial] = []
    for (index, patch) in patches.enumerated() {
      if isCancelled() { return nil }
      autoreleasepool {
        guard let (image, crop) = texture(patch, scale: scale, mesh: mesh, consensus: consensus) else {
          result.insideFallback += patch.inside
          result.outsideFallback += patch.outside
          return
        }
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = image
        material.diffuse.minificationFilter = .linear
        material.diffuse.magnificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.diffuse.maxAnisotropy = 8
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.isDoubleSided = false
        // A single photo per triangle preserves detail instead of averaging misaligned shots.
        var remap: [UInt32: UInt32] = [:]
        func element(_ indices: [UInt32]) -> SCNGeometryElement? {
          guard !indices.isEmpty else { return nil }
          var mapped: [UInt32] = []
          mapped.reserveCapacity(indices.count)
          for id in indices {
            if let existing = remap[id] { mapped.append(existing); continue }
            let next = UInt32(positions.count / 3)
            remap[id] = next
            mapped.append(next)
            let p = mesh.position(Int(id)), n = mesh.normal(Int(id)), uv = patch.project(p)
            positions.append(contentsOf: [p.x, p.y, p.z])
            normals.append(contentsOf: [n.x, n.y, n.z])
            texcoords.append(contentsOf: [Float((CGFloat(uv.x) - crop.minX) / crop.width),
                                          Float((CGFloat(uv.y) - crop.minY) / crop.height)])
          }
          return mapped.withUnsafeBytes {
            SCNGeometryElement(data: Data($0), primitiveType: .triangles, primitiveCount: mapped.count / 3, bytesPerIndex: 4)
          }
        }
        if let e = element(patch.inside) { insideElements.append(e); insideMaterials.append(material) }
        if let e = element(patch.outside) {
          outsideElements.append(e)
          let dimmed = material.copy() as! SCNMaterial
          dimmed.multiply.contents = UIColor(white: 0.55, alpha: 1)
          outsideMaterials.append(dimmed)
        }
        result.photoCount += 1
        result.triangleCount += (patch.inside.count + patch.outside.count) / 3
        result.pixelCount += image.width * image.height
      }
      progress(0.7 + 0.3 * Double(index + 1) / Double(max(1, patches.count)))
    }
    if isCancelled() { return nil }
    func source(_ data: [Float], _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
      data.withUnsafeBytes {
        SCNGeometrySource(data: Data($0), semantic: semantic, vectorCount: data.count / components,
                          usesFloatComponents: true, componentsPerVector: components, bytesPerComponent: 4,
                          dataOffset: 0, dataStride: components * 4)
      }
    }
    let sources = [source(positions, .vertex, 3), source(normals, .normal, 3), source(texcoords, .texcoord, 2)]
    if !insideElements.isEmpty {
      result.inside = SCNGeometry(sources: sources, elements: insideElements)
      result.inside?.materials = insideMaterials
    }
    if !outsideElements.isEmpty {
      result.outside = SCNGeometry(sources: sources, elements: outsideElements)
      result.outside?.materials = outsideMaterials
    }
    return result
  }

  /// Decode in sensor orientation, crop, and copy into a compact sRGB buffer. Copying releases the
  /// full decoded source rather than retaining it behind CGImage's cropped data provider.
  private static func texture(_ patch: Patch, scale: Double, mesh: PLYMesh, consensus: [UInt8]?) -> (CGImage, CGRect)? {
    guard let src = CGImageSourceCreateWithURL(patch.photo.url as CFURL, nil) else { return nil }
    let longest = max(patch.photo.width, patch.photo.height)
    let maxPixels = max(1, min(longest, Int(Double(longest) * scale)))
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                  kCGImageSourceCreateThumbnailWithTransform: false,
                                  kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                  kCGImageSourceShouldCacheImmediately: true]
    guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    let sx = CGFloat(image.width) / CGFloat(patch.photo.width), sy = CGFloat(image.height) / CGFloat(patch.photo.height)
    let crop = patch.crop
    let pixels = CGRect(x: crop.minX * sx, y: crop.minY * sy, width: crop.width * sx, height: crop.height * sy)
      .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard pixels.width > 0, pixels.height > 0, let cropped = image.cropping(to: pixels),
          let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                  bytesPerRow: cropped.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
    if let data = context.data {
      let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
      let gain = levels(patch, mesh: mesh, consensus: consensus, pixels: bytes, width: context.width, height: context.height,
                        bytesPerRow: context.bytesPerRow, origin: pixels.origin, sx: sx, sy: sy)
      apply(gain, to: bytes, width: context.width, height: context.height, bytesPerRow: context.bytesPerRow)
    }
    guard let compact = context.makeImage() else { return nil }
    return (compact, CGRect(x: pixels.minX / sx, y: pixels.minY / sy, width: pixels.width / sx, height: pixels.height / sy))
  }

  // MARK: levelling

  private static let toLinear: [Float] = (0..<256).map { i in
    let v = Float(i) / 255
    return v <= 0.04045 ? v / 12.92 : powf((v + 0.055) / 1.055, 2.4)
  }

  /// Per-channel gain (linear light) that brings the photo to the consensus color at the vertices it
  /// paints, so neighboring patches agree: brightness by up to about ±1.3 stops, tint by up to 25%
  /// (white balance is locked per room, so a big tint change is a strongly colored surface, not the
  /// camera). Clipped pixels say nothing about exposure and are skipped. Falls back to the recorded
  /// exposure's gain with too little to compare.
  @_optimize(speed)
  private static func levels(_ patch: Patch, mesh: PLYMesh, consensus: [UInt8]?, pixels: UnsafePointer<UInt8>,
                             width: Int, height: Int, bytesPerRow: Int, origin: CGPoint, sx: CGFloat, sy: CGFloat) -> SIMD3<Float> {
    let fallback = SIMD3<Float>(repeating: patch.photo.gain)
    guard let consensus, consensus.count == mesh.vertexCount * 4 else { return fallback }
    let ids = patch.inside + patch.outside
    let step = max(1, ids.count / 6000)
    var photo = SIMD3<Float>.zero, target = SIMD3<Float>.zero
    var samples = 0
    var k = 0
    while k < ids.count {
      let id = Int(ids[k])
      k += step
      let uv = patch.project(mesh.position(id))
      let x = Int(CGFloat(uv.x) * sx - origin.x), y = Int(CGFloat(uv.y) * sy - origin.y)
      guard x >= 0, y >= 0, x < width, y < height else { continue }
      let o = y * bytesPerRow + x * 4
      let r = pixels[o], g = pixels[o + 1], b = pixels[o + 2]
      if max(r, g, b) >= 250 || max(r, g, b) <= 6 { continue }
      photo += SIMD3(toLinear[Int(r)], toLinear[Int(g)], toLinear[Int(b)])
      target += SIMD3(toLinear[Int(consensus[4 * id])], toLinear[Int(consensus[4 * id + 1])], toLinear[Int(consensus[4 * id + 2])])
      samples += 1
    }
    let luma = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    guard samples >= 32, photo.min() > 0, simd_dot(target, luma) > 0 else { return fallback }
    let brightness = simd_dot(target, luma) / simd_dot(photo, luma)
    let tint = simd_clamp(target / photo / brightness, SIMD3<Float>(repeating: 0.8), SIMD3<Float>(repeating: 1.25))
    return min(2.5, max(0.4, brightness)) * tint
  }

  /// Scale the opaque RGBA pixels by `gain` in linear light, in place
  @_optimize(speed)
  private static func apply(_ gain: SIMD3<Float>, to pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
    guard simd_abs(gain - 1).max() > 0.01 else { return }
    // one lookup table per channel, back-to-back: r 0..<256, g 256..<512, b 512..<768
    let table: [UInt8] = (0..<768).map { i in
      let l = min(1, toLinear[i % 256] * gain[i / 256])
      let s = l <= 0.0031308 ? l * 12.92 : 1.055 * powf(l, 1 / 2.4) - 0.055
      return UInt8(max(0, min(255, (s * 255).rounded())))
    }
    table.withUnsafeBufferPointer { tb in
      let t = tb.baseAddress!
      var y = 0
      while y < height {
        var o = y * bytesPerRow
        let end = o + width * 4
        while o < end {
          pixels[o] = t[Int(pixels[o])]
          pixels[o + 1] = t[256 + Int(pixels[o + 1])]
          pixels[o + 2] = t[512 + Int(pixels[o + 2])]
          o += 4
        }
        y += 1
      }
    }
  }
}
