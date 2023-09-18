//
//  MM4MassParameters.swift
//  MolecularRendererApp
//
//  Created by Philip Turner on 9/11/23.
//

import Foundation

class MM4MassParameters {
  static let global = MM4MassParameters()
  
  init() {
    
  }
  
  func mass(atomicNumber: UInt8) -> Float {
    Float(Self.sourceData[Int(atomicNumber)])
  }
}

extension MM4MassParameters {
  static let sourceData: [Double] = [
    0,
    1.008,
    4.0026022,
    6.94,
    9.01218315,
    10.81,
    12.011,
    14.007,
    15.999,
    18.9984031636,
    20.17976,
    22.989769282,
    24.305,
    26.98153857,
    28.085,
    30.9737619985,
    32.06,
    35.45,
    39.9481,
    39.09831,
    40.0784,
    44.9559085,
    47.8671,
    50.94151,
    51.99616,
    54.9380443,
    55.8452,
    58.9331944,
    58.69344,
    63.5463,
    65.382,
    69.7231,
    72.6308,
    74.9215956,
    78.9718,
    79.904,
    83.7982,
    85.46783,
    87.621,
    88.905842,
    91.2242,
    92.906372,
    95.951,
    98.0,
    101.072,
    102.905502,
    106.421,
    107.86822,
    112.4144,
    114.8181,
    118.7107,
    121.7601,
    127.603,
    126.904473,
    131.2936,
    132.905451966,
    137.3277,
    138.905477,
    140.1161,
    140.907662,
    144.2423,
    145.0,
    150.362,
    151.9641,
    157.253,
    158.925352,
    162.5001,
    164.930332,
    167.2593,
    168.934222,
    173.0451,
    174.96681,
    178.492,
    180.947882,
    183.841,
    186.2071,
    190.233,
    192.2173,
    195.0849,
    196.9665695,
    200.5923,
    204.38,
    207.21,
    208.980401,
    209.0,
    210.0,
    222.0,
    223.0,
    226.0,
    227.0,
    232.03774,
    231.035882,
    238.028913,
    237.0,
    244.0,
    243.0,
    247.0,
    247.0,
    251.0,
    252.0,
    257.0,
    258.0,
    259.0,
    266.0,
    267.0,
    268.0,
    269.0,
    270.0,
    269.0,
    278.0,
    281.0,
    282.0,
    285.0,
    286.0,
    289.0,
    289.0,
    293.0,
    294.0,
    294.0,
    315.0,
  ]
}
