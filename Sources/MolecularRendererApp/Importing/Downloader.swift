//
//  Downloader.swift
//  MolecularRendererApp
//
//  Created by Philip Turner on 6/10/23.
//

import Foundation
import QuartzCore

fileprivate let logDownloadLatency = false

struct Downloader {
  private var url: URL
  private(set) var latency: Double
  private(set) var data: Data
  var string: String { String(data: data, encoding: .utf8)! }
  
  // Immediately downloads the file upon initialization, blocking the caller.
  init(url: URL) throws {
    let start = CACurrentMediaTime()
    let data = try Data(contentsOf: url)
    let end = CACurrentMediaTime()
    
    self.url = url
    self.data = data
    self.latency = end - start
  }
  
  func logLatency() {
    if logDownloadLatency {
      print("Downloaded in \(latencyRepr(latency))")
      print("- path: \(url)")
    }
  }
}
