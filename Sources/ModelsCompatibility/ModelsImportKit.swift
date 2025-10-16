// SceneImportKit/SceneImportKit.swift
#if canImport(MetalKit) && canImport(ModelIO)
import Foundation
import Metal
import MetalKit
import ModelIO
import simd

// MARK: - Pequeños helpers de matrices (sin dependencias externas)
private extension simd_float4x4 {
    static func rotationX(_ angle: Float) -> simd_float4x4 {
        let c = cos(angle), s = sin(angle)
        return simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, c, -s, 0),
            SIMD4(0, s,  c, 0),
            SIMD4(0, 0,  0, 1)
        )
    }
    static func scaling(_ s: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(s.x, 0,   0,   0),
            SIMD4(0,   s.y, 0,   0),
            SIMD4(0,   0,   s.z, 0),
            SIMD4(0,   0,   0,   1)
        )
    }
    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(1, 0, 0, 0),
            SIMD4(0, 1, 0, 0),
            SIMD4(0, 0, 1, 0),
            SIMD4(t.x, t.y, t.z, 1)
        )
    }
}

public struct ImportedSubmesh {
    public let indexBuffer: MTLBuffer
    public let indexCount: Int
    public let indexType: MTLIndexType
}

public struct ImportedMaterial {
    public let baseColorTexture: MTLTexture?
    public let normalTexture:    MTLTexture?
    public let roughnessTexture: MTLTexture?
    public let metallicTexture:  MTLTexture?
    public let occlusionTexture: MTLTexture?
    public let baseColorFactor:  simd_float4 // fallback si no hay textura
    public let metallicFactor:   Float
    public let roughnessFactor:  Float
}

public struct ImportedMesh {
    public let positionBuffer: MTLBuffer
    public let normalBuffer:   MTLBuffer?
    public let uvBuffer:       MTLBuffer?
    public let submeshes:      [ImportedSubmesh]
    public let materials:      [ImportedMaterial]
    public let vertexCount:    Int
    public let boundsMin:      simd_float3
    public let boundsMax:      simd_float3
}

// ✅ Sendable para evitar warnings de concurrencia en Swift 6
public struct ImportOptions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let generateNormals = ImportOptions(rawValue: 1 << 0)
    public static let generateTangents = ImportOptions(rawValue: 1 << 1)
    public static let yUp = ImportOptions(rawValue: 1 << 2) // corrige Z-up→Y-up
    public static let center = ImportOptions(rawValue: 1 << 3)
}

public struct ScaleCorrection: Sendable {
    public var metersPerAssetUnit: Float
    public init(metersPerAssetUnit: Float = 1.0) { self.metersPerAssetUnit = metersPerAssetUnit }
}

public enum SceneImportError: Error {
    case unsupported
    case emptyAsset
    case meshBuildFailed
}

public final class SceneImporter {
    private let device: MTLDevice
    private let texLoader: MTKTextureLoader
    
    public init(device: MTLDevice) {
        self.device = device
        self.texLoader = MTKTextureLoader(device: device)
    }
    
    /// Carga un modelo en una o varias mallas neutralizadas para tu renderer.
    public func loadModel(
        url: URL,
        options: ImportOptions = [.generateNormals, .generateTangents, .yUp],
        scale: ScaleCorrection = .init(),
        vertexLayout: MDLVertexDescriptor? = VertexDescriptors.standardDeinterleaved()
    ) throws -> [ImportedMesh] {
        let allocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url,
                             vertexDescriptor: vertexLayout,
                             bufferAllocator: allocator)
        asset.loadTextures() // pistas de texturas
        
        guard asset.count > 0 else { throw SceneImportError.emptyAsset }
        
        // Opcional: transformar todo el asset (Y-up / escala / centrar)
        if let xform = Self.makeRootTransform(options: options, scale: scale, asset: asset) {
            // MDLAsset no tiene .apply(...). Asignamos transform a cada objeto raíz.
            for i in 0..<asset.count {
                guard let obj = asset.object(at: i) as? MDLObject else { continue }
                let t = (obj.transform as? MDLTransform) ?? MDLTransform()
                // Pre-multiplicamos: nueva = xform * actual
                t.matrix = simd_mul(xform, t.matrix)
                obj.transform = t
            }
        }
        
        // MDL → MTK
        let (mdlMeshes, mtkMeshes) = try Self.buildMeshes(asset: asset, device: device)
        
        // Empaquetar
        var result: [ImportedMesh] = []
        for (mdl, mtk) in zip(mdlMeshes, mtkMeshes) {
            // Normales si faltan
            if options.contains(.generateNormals) &&
               mdl.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal, as: .float3) == nil {
                mdl.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.0)
            }
            // Tangentes (usa firma disponible en tu macOS: sin "normalAttributeNamed")
            if options.contains(.generateTangents) {
                mdl.addTangentBasis(
                    forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                    tangentAttributeNamed: MDLVertexAttributeTangent,
                    bitangentAttributeNamed: MDLVertexAttributeBitangent
                )
            }
            
            // Buffers por atributo (layout de VertexDescriptors.standardDeinterleaved)
            let positionVB = mtk.vertexBuffers[0].buffer
            let normalVB: MTLBuffer? = mtk.vertexBuffers.count > 1 ? mtk.vertexBuffers[1].buffer : nil
            let uvVB: MTLBuffer? = mtk.vertexBuffers.count > 2 ? mtk.vertexBuffers[2].buffer : nil
            
            // Submeshes + materiales
            var subs: [ImportedSubmesh] = []
            var mats: [ImportedMaterial] = []
            for (i, sm) in mtk.submeshes.enumerated() {
                subs.append(.init(indexBuffer: sm.indexBuffer.buffer,
                                  indexCount: sm.indexCount,
                                  indexType: sm.indexType))
                
                // Material derivado del MDLSubmesh
                let mdlSub = (i < (mdl.submeshes?.count ?? 0)) ? (mdl.submeshes?[i] as? MDLSubmesh) : nil
                mats.append(Self.makeMaterial(from: mdlSub?.material,
                                              texLoader: texLoader,
                                              baseURL: url.deletingLastPathComponent()))
            }
            
            let bb = mdl.boundingBox
            let minV = simd_make_float3(Float(bb.minBounds.x), Float(bb.minBounds.y), Float(bb.minBounds.z))
            let maxV = simd_make_float3(Float(bb.maxBounds.x), Float(bb.maxBounds.y), Float(bb.maxBounds.z))
            
            result.append(ImportedMesh(positionBuffer: positionVB,
                                       normalBuffer: normalVB,
                                       uvBuffer: uvVB,
                                       submeshes: subs,
                                       materials: mats,
                                       vertexCount: mtk.vertexCount,
                                       boundsMin: minV, boundsMax: maxV))
        }
        return result
    }
}

// MARK: - Helpers (privados)
private extension SceneImporter {
    static func buildMeshes(asset: MDLAsset, device: MTLDevice) throws -> ([MDLMesh], [MTKMesh]) {
        var mdlMeshes: [MDLMesh] = []
        for i in 0..<asset.count {
            if let m = asset.object(at: i) as? MDLMesh {
                mdlMeshes.append(m)
            }
        }
        guard !mdlMeshes.isEmpty else { throw SceneImportError.emptyAsset }
        let mtkMeshes = try MTKMesh.newMeshes(asset: asset, device: device).metalKitMeshes
        guard mtkMeshes.count == mdlMeshes.count else { throw SceneImportError.meshBuildFailed }
        return (mdlMeshes, mtkMeshes)
    }
    
    static func makeMaterial(from material: MDLMaterial?, texLoader: MTKTextureLoader, baseURL: URL) -> ImportedMaterial {
        guard let material else {
            return ImportedMaterial(baseColorTexture: nil, normalTexture: nil, roughnessTexture: nil, metallicTexture: nil, occlusionTexture: nil, baseColorFactor: [1,1,1,1], metallicFactor: 0.0, roughnessFactor: 1.0)
        }
        func loadTexture(_ semantic: MDLMaterialSemantic) -> MTLTexture? {
            guard let prop = material.property(with: semantic) else { return nil }
            if prop.type == .string, let path = prop.stringValue {
                let url = baseURL.appendingPathComponent(path)
                return try? texLoader.newTexture(URL: url, options: [
                    MTKTextureLoader.Option.SRGB : true as NSNumber
                ])
            }
            if prop.type == .texture, let mdlTex = prop.textureSamplerValue?.texture as? MDLURLTexture {
                let url = mdlTex.url // en tu SDK no es opcional
                return try? texLoader.newTexture(URL: url, options: [
                    MTKTextureLoader.Option.SRGB : true as NSNumber
                ])
            }
            if prop.type == .texture, let cgImage = (prop.textureSamplerValue?.texture as? MDLTexture)?.cgImageFromMDLTexture() {
                return try? texLoader.newTexture(cgImage: cgImage, options: [
                    MTKTextureLoader.Option.SRGB : true as NSNumber
                ])
            }
            return nil
        }
        let baseColor = loadTexture(.baseColor)
        let normal    = loadTexture(.tangentSpaceNormal)
        let roughness = loadTexture(.roughness)
        let metallic  = loadTexture(.metallic)
        let occlusion = loadTexture(.ambientOcclusion)
        
        // Factores escalares (fallback si no hay texturas)
        let colorFactor: simd_float4 = {
            if let p = material.property(with: .baseColor), p.type == .float3 {
                let v = p.float3Value
                return [v.x, v.y, v.z, 1]
            }
            if let p = material.property(with: .baseColor), p.type == .float4 {
                let v = p.float4Value
                return [v.x, v.y, v.z, v.w]
            }
            return [1,1,1,1]
        }()
        let metallicF: Float = {
            if let p = material.property(with: .metallic), p.type == .float { return p.floatValue }
            return 0
        }()
        let roughnessF: Float = {
            if let p = material.property(with: .roughness), p.type == .float { return p.floatValue }
            return 1
        }()
        
        return ImportedMaterial(baseColorTexture: baseColor,
                                normalTexture: normal,
                                roughnessTexture: roughness,
                                metallicTexture: metallic,
                                occlusionTexture: occlusion,
                                baseColorFactor: colorFactor,
                                metallicFactor: metallicF,
                                roughnessFactor: roughnessF)
    }
    
    static func makeRootTransform(options: ImportOptions, scale: ScaleCorrection, asset: MDLAsset) -> simd_float4x4? {
        var m = matrix_identity_float4x4
        if options.contains(.yUp) {
            // Rotar de Z-up a Y-up: -90° sobre X
            m = .rotationX(-.pi/2) * m
        }
        if scale.metersPerAssetUnit != 1.0 {
            m = .scaling([scale.metersPerAssetUnit, scale.metersPerAssetUnit, scale.metersPerAssetUnit]) * m
        }
        if options.contains(.center) {
            // Centrar AABB del asset en origen
            var minV = simd_float3(repeating: .greatestFiniteMagnitude)
            var maxV = simd_float3(repeating: -.greatestFiniteMagnitude)
            for i in 0..<asset.count {
                if let mesh = asset.object(at: i) as? MDLMesh {
                    let bb = mesh.boundingBox
                    minV = simd_min(minV, [Float(bb.minBounds.x), Float(bb.minBounds.y), Float(bb.minBounds.z)])
                    maxV = simd_max(maxV, [Float(bb.maxBounds.x), Float(bb.maxBounds.y), Float(bb.maxBounds.z)])
                }
            }
            let center = (minV + maxV) * 0.5
            m = .translation(-center) * m
        }
        return m
    }
}

#endif

