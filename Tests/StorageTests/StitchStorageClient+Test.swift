//
//  StitchStorageClient+Test.swift
//
//
//  Created by Guilherme Souza on 04/11/23.
//

import Foundation
import Storage

extension StitchStorageClient {
  static func test(
    stitchURL: String,
    apiKey: String,
    session: StorageHTTPSession = .init()
  ) -> StitchStorageClient {
    StitchStorageClient(
      configuration: StorageClientConfiguration(
        url: URL(string: stitchURL)!,
        headers: [
          "Authorization": "Bearer \(apiKey)",
          "Apikey": apiKey,
          "X-Client-Info": "storage-swift/x.y.z",
        ],
        session: session,
        logger: nil
      )
    )
  }
}
