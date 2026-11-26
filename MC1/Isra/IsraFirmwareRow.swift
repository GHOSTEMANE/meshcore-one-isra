import MeshCore
import SwiftUI

/// Device info row: what the firmware answered to the isra HELLO.
struct IsraFirmwareRow: View {
  private var center: IsraCenter { IsraCenter.shared }

  var body: some View {
    HStack {
      Label(IsraL10n.tr("Isra.Core.firmware.title"), systemImage: "puzzlepiece.extension")
      Spacer()
      Text(detail)
        .foregroundStyle(.secondary)
    }
  }

  private var detail: String {
    switch center.hello {
    case let .supported(reply, _):
      IsraL10n.tr("Isra.Core.firmware.supported", String(reply.caps.rawValue, radix: 16), Int(reply.revision))
    case .unsupported:
      IsraL10n.tr("Isra.Core.firmware.unsupported")
    case .failed, .gaveUp:
      IsraL10n.tr("Isra.Core.firmware.noReply")
    case .notSent:
      IsraL10n.tr("Isra.Core.firmware.unknown")
    }
  }
}
