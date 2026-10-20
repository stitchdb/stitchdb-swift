//
//  Constants.swift
//  StitchDB
//
//  Created by Guilherme Souza on 06/03/25.
//

import Foundation

let defaultHeaders: [String: String] = {
  var clientInfo = "stitchdb-swift/\(version)"

  if let platform {
    clientInfo += "; platform=\(platform)"
  }

  if let platformVersion {
    clientInfo += "; platform-version=\(platformVersion)"
  }

  clientInfo += "; runtime=swift"

  if let runtimeVersion {
    clientInfo += "; runtime-version=\(runtimeVersion)"
  }

  return ["X-Client-Info": clientInfo]
}()
