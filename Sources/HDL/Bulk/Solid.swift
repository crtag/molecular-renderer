//
//  Solid.swift
//  MolecularRendererApp
//
//  Created by Philip Turner on 9/1/23.
//

import Foundation

public struct Solid {
  var centers: [SIMD3<Float>] = []
  
  /// Unstable API; do not use this function.
  ///
  /// Right now, returns centers in the diamond `Cubic` basis. They are measured
  /// in multiples of 0.357 nm, not in nanometers.
  public var _centers: [SIMD3<Float>] { centers }
  
  public init(_ closure: () -> Void) {
    Compiler.global.startSolid()
    closure()
    self.centers = Compiler.global.endSolid()
  }
}

// Adds atoms to the scene, aligned with the crystal plane
public struct Copy {
  private var centers: [SIMD3<Float>] = []
  
  @discardableResult
  public init<T>(_ closure: () -> Lattice<T>) {
    Compiler.global.performCopy(closure().centers)
  }
  
  @discardableResult
  public init(_ closure: () -> Solid) {
    Compiler.global.performCopy(closure().centers)
  }
}
