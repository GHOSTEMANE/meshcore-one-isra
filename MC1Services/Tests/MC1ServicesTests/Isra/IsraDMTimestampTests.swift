import Foundation
@testable import MC1Services
import MeshCore
import Testing

/// Host DM timestamps with SENT_MSGS in effect (isra/PROTOCOL.md section 3).
@Suite("isra DM timestamps")
struct IsraDMTimestampTests {
  @Test
  func `without SENT_MSGS the timestamp is upstream's plain one`() {
    let odd = Date(timeIntervalSince1970: 1_800_000_001.7)
    #expect(MessageService.israDirectMessageTimestamp(now: odd, sentMessagesActive: false) == 1_800_000_001)
    let even = Date(timeIntervalSince1970: 1_800_000_002)
    #expect(MessageService.israDirectMessageTimestamp(now: even, sentMessagesActive: false) == 1_800_000_002)
  }

  @Test
  func `with SENT_MSGS timestamps are even and strictly increasing`() {
    // Far ahead of the wall clock, so whatever the process-wide state holds stays behind.
    let now = Date(timeIntervalSince1970: 3_000_000_001)
    var previous: UInt32 = 0
    for _ in 0..<4 {
      let value = MessageService.israDirectMessageTimestamp(now: now, sentMessagesActive: true)
      #expect(value % 2 == 0)
      #expect(value >= 3_000_000_002)
      #expect(value > previous)
      previous = value
    }
    // Never more than one second ahead for the first DM of a second.
    let later = Date(timeIntervalSince1970: 3_000_000_101)
    #expect(MessageService.israDirectMessageTimestamp(now: later, sentMessagesActive: true) == 3_000_000_102)
  }
}
