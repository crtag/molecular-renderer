//
//  Serializer.swift
//  MolecularRendererApp
//
//  Created by Philip Turner on 7/23/23.
//

import Metal
import MolecularRenderer

class Serializer {
  unowned let renderer: Renderer
  var path: String
  
  init(renderer: Renderer, path: String) {
    self.renderer = renderer
    self.path = path
  }
  
  func load(fileName: String) -> MRSimulation {
    let path = self.path + "/" + fileName + ".mrsim"
    let url = URL(filePath: path)
    return MRSimulation(
      renderer: renderer.renderingEngine, url: url)
  }
  
  func save(
    fileName: String,
    provider: OpenMM_AtomProvider,
    asText: Bool = false
  ) {
    // Allow 0.125 fs precision.
    var frameTimeInFs = rint(8 * 1000 * provider.psPerStep) / 8
    frameTimeInFs *= Double(provider.stepsPerFrame)
    let simulation = MRSimulation(
      renderer: renderer.renderingEngine,
      frameTimeInFs: frameTimeInFs,
      format: asText ? .plainText : .binary)
    
    for state in provider.states {
      let frame = MRFrame(atoms: state)
      simulation.append(frame)
    }
    
    var path = self.path + "/" + fileName + ".mrsimulation"
    if asText {
      path.removeLast("ulation".count)
      path += "-txt"
    }
    let url = URL(filePath: path)
    simulation.save(url: url)
  }
}

struct SimulationAtomProvider: MRAtomProvider {
  var frameTimeInFs: Double
  var frames: [[MRAtom]] = []
  
  init(simulation: MRSimulation) {
    self.frameTimeInFs = simulation.frameTimeInFs
    for frameID in 0..<simulation.frameCount {
      let frame = simulation.frame(id: frameID)
      frames.append(frame.atoms)
    }
    
    // This metric is not accurate when you're rendering offline.
//    let ps = (frameTimeInFs * 120) / 1000
//    print()
//    print("Replaying at \(ps) ps/s.")
  }
  
  func atoms(time: MRTimeContext) -> [MRAtom] {
    let frameID = min(time.absolute.frames, frames.count - 1)
//    let ps = 1 / 1000 * Double(frameID) * frameTimeInFs
    return frames[frameID]
  }
}
