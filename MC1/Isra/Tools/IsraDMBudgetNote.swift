import MC1Services
import SwiftUI

/// The DM retry settings already exist upstream (Settings > Advanced > Direct messages:
/// direct attempts 1-4 = 0-3 retries, flood fallback on/off with 1-4 flood attempts,
/// read by `DMSendBudget.current()` for every send). This only spells out what the
/// current choice costs on air, worst case.
enum IsraDMBudget {
  /// The wire attempt byte caps a message at 8 transmissions (`AckCodeBuilder.attemptCount`).
  static let wireCap = 8

  static func worstCase(_ budget: DMSendBudget) -> (direct: Int, flood: Int, total: Int) {
    let direct = min(budget.directAttempts, wireCap)
    let flood = min(budget.floodAttempts, wireCap - direct)
    return (direct, flood, direct + flood)
  }
}

struct IsraDMBudgetNote: View {
  @Environment(\.appTheme) private var theme
  @AppStorage(AppStorageKey.dmDirectAttempts.rawValue)
  private var storedDirect = AppStorageKey.defaultDMDirectAttempts
  @AppStorage(AppStorageKey.dmFloodAttempts.rawValue)
  private var storedFlood = AppStorageKey.defaultDMFloodAttempts

  var body: some View {
    let cost = IsraDMBudget.worstCase(DMSendBudget(directAttempts: storedDirect, floodAttempts: storedFlood))
    Section {
      LabeledContent(IsraL10n.tr("Isra.Tools.DM.worstCase")) {
        Text(IsraL10n.tr("Isra.Tools.DM.worstCaseValue", cost.total, cost.direct, cost.flood))
          .monospacedDigit()
      }
    } footer: {
      Text(IsraL10n.tr(
        "Isra.Tools.DM.footer", DMSendBudget.defaultDirectAttempts, DMSendBudget.defaultFloodAttempts
      ))
    }
    .themedRowBackground(theme)
  }
}
