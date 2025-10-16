//
//  VertexDescriptors.swift
//  ModelsCompatibility
//
//  Created by Miguel Carlos Elizondo Mrtinez on 16/10/25.
//

// SceneImportKit/VertexDescriptors.swift
#if canImport(ModelIO)
import ModelIO

public enum VertexDescriptors {
    /// attr0: position (float3) in buffer(0)
    /// attr1: normal   (float3) in buffer(1)
    /// attr2: uv       (float2) in buffer(2)
    public static func standardDeinterleaved() -> MDLVertexDescriptor {
        let v = MDLVertexDescriptor()
        
        // Positions
        v.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                             format: .float3,
                                             offset: 0,
                                             bufferIndex: 0)
        v.layouts[0] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 3)
        
        // Normals
        v.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal,
                                             format: .float3,
                                             offset: 0,
                                             bufferIndex: 1)
        v.layouts[1] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 3)
        
        // UVs
        v.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                             format: .float2,
                                             offset: 0,
                                             bufferIndex: 2)
        v.layouts[2] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 2)
        return v
    }
}
#endif
