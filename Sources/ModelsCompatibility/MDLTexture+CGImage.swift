// SceneImportKit/MDLTexture+CGImage.swift
#if canImport(ModelIO) && canImport(CoreGraphics)
import ModelIO
import CoreGraphics
import ImageIO
import CoreImage

public extension MDLTexture {
    /// Mejor esfuerzo para obtener CGImage desde MDLTexture en memoria.
    func cgImageFromMDLTexture() -> CGImage? {
        guard let data = self.texelDataWithTopLeftOrigin() else { return nil }
        let width = Int(self.dimensions.x)
        let height = Int(self.dimensions.y)
        let bitsPerComponent = 8
        let bytesPerPixel = 4
        let bytesPerRow = Int(width) * bytesPerPixel
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return data.withUnsafeBytes { raw in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: raw.baseAddress),
                                      width: width, height: height,
                                      bitsPerComponent: bitsPerComponent, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}
#endif

