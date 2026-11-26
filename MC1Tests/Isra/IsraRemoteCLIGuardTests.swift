import Foundation
@testable import MC1
import Testing

/// isra: the remote-node CLI refuses OTA/DFU like the local one; `reboot` still goes.
@Suite("isra remote CLI guard")
@MainActor
struct IsraRemoteCLIGuardTests {
  @MainActor
  private final class Sent {
    var commands: [String] = []
  }

  private func makeModel(_ sent: Sent) -> NodeCLIViewModel {
    let model = NodeCLIViewModel()
    model.configure(sessionName: "SE.STB R8", remoteTarget: .radio) { command, _ in
      sent.commands.append(command)
      return "OK"
    }
    return model
  }

  @Test
  func `start ota is refused and never sent`() {
    let sent = Sent()
    let model = makeModel(sent)
    model.executeCommand("start ota")
    #expect(sent.commands.isEmpty)
    #expect(!model.isWaitingForResponse)
    #expect(model.outputLines.contains { $0.type == .error && $0.text == IsraL10n.tr("Isra.UI.OTA.blocked") })
  }

  @Test
  func `remote reboot still goes`() async throws {
    let sent = Sent()
    let model = makeModel(sent)
    model.executeCommand("reboot")
    let deadline = ContinuousClock.now + .seconds(10)
    while sent.commands.isEmpty, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sent.commands == ["reboot"])
  }
}
