//
//  Serialization.metal
//  MolecularRendererGPU
//
//  Created by Philip Turner on 7/26/23.
//

#include <metal_stdlib>
#include "../Utilities/MRAtom.metal"
using namespace metal;

struct process_atoms_arguments {
  ushort cluster_size;
  float scale_factor;
  float inverse_scale_factor;
};

// TODO: To scale this to millions of atoms, create groups of checkpoint frames.
// Store the bulk of the data as deltas from the nearest checkpoint.
constant bool encode [[function_constant(300)]];

kernel void process_atoms
(
 constant process_atoms_arguments &args [[buffer(0)]],
 constant uint2 *frame_ranges [[buffer(1)]],
 
 device MRAtom *atoms [[buffer(2)]],
 device ushort *tail_components [[buffer(3)]],
 device uint *x_components [[buffer(4)]],
 device uint *y_components [[buffer(5)]],
 device uint *z_components [[buffer(6)]],
 
 uint tid [[thread_position_in_grid]])
{
  for (uint frame = 0; frame < args.cluster_size; ++frame) {
    uint2 range = frame_ranges[frame];
    uint atoms_cursor = range[0] + tid;
    uint components_cursor = tid * args.cluster_size + frame;
    
    if (encode) {
      MRAtom atom;
      if (tid < range[1]) {
        atom = MRAtom(atoms + atoms_cursor);
      } else {
        atom = MRAtom(float3(0), ushort(0));
      }
      
      float3 xyz = rint(atom.origin * args.scale_factor);
      uint3 xyz_quantized = uint3(abs(xyz)) << 1;
      xyz_quantized |= select(uint3(0), uint3(1), xyz < 0);
      
      x_components[components_cursor] = xyz_quantized.x;
      y_components[components_cursor] = xyz_quantized.y;
      z_components[components_cursor] = xyz_quantized.z;
      tail_components[components_cursor] = atom.tailStorage;
    } else {
      if (tid >= range[1]) {
        continue;
      }
      
      uint3 xyz_quantized(x_components[components_cursor],
                          y_components[components_cursor],
                          z_components[components_cursor]);
      ushort3 xyz_signs = ushort3(xyz_quantized & 1);
      xyz_quantized >>= 1;
      
      float3 xyz = float3(xyz_quantized) * args.inverse_scale_factor;
      xyz = select(xyz, -xyz, bool3(xyz_signs));
      
      ushort tail = tail_components[components_cursor];
      MRAtom atom(xyz, tail);
      atom.store(atoms + atoms_cursor);
    }
  }
}
