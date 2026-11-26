import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

@Suite("isra CLI guard")
struct IsraCLIGuardTests {
  @Test
  func `local reboot is refused but remote reboot is allowed`() {
    #expect(IsraCLIGuard.refusal(for: "reboot", isLocal: true) == .localReboot)
    #expect(IsraCLIGuard.refusal(for: "  REBOOT ", isLocal: true) == .localReboot)
    #expect(IsraCLIGuard.refusal(for: "reboot", isLocal: false) == nil)
    #expect(IsraCLIGuard.refusal(for: "get name", isLocal: true) == nil)
  }

  @Test
  func `OTA and DFU are refused everywhere`() {
    for local in [true, false] {
      #expect(IsraCLIGuard.refusal(for: "start ota", isLocal: local) == .ota)
      #expect(IsraCLIGuard.refusal(for: "START OTA", isLocal: local) == .ota)
      #expect(IsraCLIGuard.refusal(for: "ota", isLocal: local) == .ota)
      #expect(IsraCLIGuard.refusal(for: "dfu", isLocal: local) == .ota)
      #expect(IsraCLIGuard.refusal(for: "start ota.update", isLocal: local) == .ota)
      #expect(IsraCLIGuard.refusal(for: "set name Otavio", isLocal: local) == nil)
    }
  }

  @Test
  func `completions hide start and OTA and local reboot`() {
    #expect(IsraCLIGuard.hidesCompletion("start", isLocal: false))
    #expect(IsraCLIGuard.hidesCompletion("reboot", isLocal: true))
    #expect(!IsraCLIGuard.hidesCompletion("reboot", isLocal: false))
    #expect(!IsraCLIGuard.hidesCompletion("get", isLocal: true))
  }
}
