//
//  Basis.swift
//  MolecularRendererApp
//
//  Created by Philip Turner on 9/1/23.
//

public protocol Basis {
  
}

public struct Cubic: Basis {
  
}

public struct Hexagonal: Basis {
  
}

public struct Bounds {
  @discardableResult
  public init(_ position: () -> Vector<Cubic>) {
    // Initialize the atoms to a cuboid.
    let vector = position()
    guard let x = Int32(exactly: vector.simdValue.x),
          let y = Int32(exactly: vector.simdValue.y),
          let z = Int32(exactly: vector.simdValue.z) else {
      fatalError("Bounds must be integer quantities of crystal unit cells.")
    }
    Compiler.global.setBounds(SIMD3(x, y, z))
  }
  
  @discardableResult
  public init(_ position: () -> Vector<Hexagonal>) {
    // Initialize the atoms to a hexagonal prism.
    fatalError("Not implemented.")
  }
}
