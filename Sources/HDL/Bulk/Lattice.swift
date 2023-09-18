//
//  Crystal.swift
//  MolecularRenderer
//
//  Created by Philip Turner on 9/1/23.
//

// While inside a lattice, all translations and rotations must perfectly align
// with the lattice. That way, atoms can be de-duplicated when fusing through
// constructive solid geometry. After breaking out of the lattice, covalent
// bonds are formed and surfaces are passivated. Atoms can't be de-duplicated
// anymore. However, the same types of transforms can be performed on atoms in
// bulk.
public struct Lattice<T: CrystalBasis> {
  var centers: [SIMD3<Float>] = []
  
  // TODO: Variable for offset of the grid's start from (0, 0, 0).
  
  /// Unstable API; do not use this function.
  public var _centers: [SIMD3<Float>] { centers }
  
  public init(_ closure: () -> Void) {
    Compiler.global.startLattice(type: T.self)
    closure()
    self.centers = Compiler.global.endLattice(type: T.self)
  }
}
