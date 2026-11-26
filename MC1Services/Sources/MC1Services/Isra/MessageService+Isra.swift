import Foundation
import MeshCore
import Synchronization

extension MessageService {
  /// isra: timestamp for a new outgoing direct message (isra/PROTOCOL.md section 3).
  ///
  /// With SENT_MSGS in effect on the session, the radio stamps the DMs composed on it
  /// with odd timestamps, so the app's go on even ones (moved up to the next even second,
  /// strictly increasing): the ACK code does not carry the recipient, and the same text
  /// sent from both in the same second would otherwise share it. Otherwise (stock
  /// firmware, no HELLO, upstream builds, test sessions) it is upstream's plain
  /// `UInt32(Date().timeIntervalSince1970)`. Retries that keep the timestamp never call this.
  func israNewDirectMessageTimestamp(now: Date = Date()) async -> UInt32 {
    var active = false
    if IsraHooks.isInstalled, let session = session as? MeshCoreSession {
      active = await session.israSentMessagesActive
    }
    return Self.israDirectMessageTimestamp(now: now, sentMessagesActive: active)
  }

  /// Upstream's plain timestamp, or the next even one when SENT_MSGS is in effect.
  static func israDirectMessageTimestamp(now: Date, sentMessagesActive: Bool) -> UInt32 {
    let plain = UInt32(now.timeIntervalSince1970)
    return sentMessagesActive ? IsraHostTimestamps.next(now: plain) : plain
  }
}

/// isra: the last even DM timestamp this app picked, process-wide, so two DMs never share
/// one (also across reconnects and radios).
enum IsraHostTimestamps {
  private static let last = Mutex<UInt32?>(nil)

  static func next(now: UInt32) -> UInt32 {
    last.withLock { last in
      let value = IsraProtocol.evenHostTimestamp(now: now, after: last)
      last = value
      return value
    }
  }
}
