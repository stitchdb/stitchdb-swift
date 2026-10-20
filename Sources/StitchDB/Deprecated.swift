//
//  Deprecated.swift
//
//
//  Created by Guilherme Souza on 15/05/24.
//

import ConcurrencyExtras
public import Foundation

extension StitchClient {
  /// Database client for StitchDB.
  @available(
    *,
    deprecated,
    message:
      "Direct access to database is deprecated, please use one of the available methods such as, StitchClient.from(_:), StitchClient.rpc(_:params:), or StitchClient.schema(_:)."
  )
  public var database: PostgrestClient {
    rest
  }

  /// Realtime client for StitchDB
  @available(*, deprecated, message: "Use realtimeV2")
  public var realtime: RealtimeClient {
    _realtime.value
  }
}
