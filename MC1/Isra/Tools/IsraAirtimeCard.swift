import MC1Services
import SwiftUI

/// Local radio TX airtime vs the 10 % limit, from the radio's own counters.
struct IsraAirtimeCard: View {
  @Environment(\.appTheme) private var theme
  @State private var meter = IsraAirtimeMeter.shared
  @State private var refreshing = false

  var body: some View {
    Section {
      if meter.unsupported {
        Text(IsraL10n.tr("Isra.Tools.Airtime.unsupported"))
          .foregroundStyle(.secondary)
      } else if meter.latest == nil {
        Text(IsraL10n.tr("Isra.Tools.Airtime.waiting"))
          .foregroundStyle(.secondary)
      } else {
        row(IsraL10n.tr("Isra.Tools.Airtime.lastHour"), meter.lastHour, fullSpan: 3600)
        row(IsraL10n.tr("Isra.Tools.Airtime.lastTenMinutes"), meter.lastTenMinutes, fullSpan: 600)
        row(IsraL10n.tr("Isra.Tools.Airtime.sinceConnect"), meter.sinceConnect, fullSpan: nil)
        row(IsraL10n.tr("Isra.Tools.Airtime.sinceBoot"), meter.sinceBoot, fullSpan: nil)
        if let latest = meter.latest {
          LabeledContent(IsraL10n.tr("Isra.Tools.Airtime.counters")) {
            Text(IsraL10n.tr(
              "Isra.Tools.Airtime.countersValue",
              Int(latest.txSeconds), Int(latest.rxSeconds), Self.duration(Double(latest.uptime))
            ))
            .font(.footnote.monospacedDigit())
          }
          .font(.footnote)
        }
      }
      Button {
        Task {
          refreshing = true
          await meter.poll()
          refreshing = false
        }
      } label: {
        HStack {
          Text(IsraL10n.tr("Isra.Tools.Airtime.refresh"))
          if refreshing {
            Spacer()
            ProgressView()
          }
        }
      }
      .disabled(refreshing)
    } header: {
      Text(IsraL10n.tr("Isra.Tools.Airtime.header"))
    } footer: {
      Text(IsraL10n.tr("Isra.Tools.Airtime.footer"))
    }
    .themedRowBackground(theme)
  }

  @ViewBuilder
  private func row(_ title: String, _ window: IsraAirtimeWindow?, fullSpan: Double?) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text(title)
        Spacer()
        if let window {
          Text(Self.percent(window.txShare))
            .font(.body.monospacedDigit().weight(.semibold))
            .foregroundStyle(Self.color(window.txShare))
        } else {
          Text(IsraL10n.tr("Isra.Tools.Airtime.notEnough"))
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      if let window {
        Gauge(value: min(window.txShare, IsraAirtimeMath.legalLimit * 1.5), in: 0...(IsraAirtimeMath.legalLimit * 1.5)) {
          EmptyView()
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(Self.color(window.txShare))
        Text(detail(window, fullSpan: fullSpan))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  private func detail(_ window: IsraAirtimeWindow, fullSpan: Double?) -> String {
    var text = IsraL10n.tr(
      "Isra.Tools.Airtime.detail",
      Int(window.txSeconds), Self.duration(window.span), Self.percent(window.shareUncertainty),
      Self.percent(window.rxShare)
    )
    if let fullSpan, window.span < fullSpan - 90 {
      text += " · " + IsraL10n.tr("Isra.Tools.Airtime.partial", Self.duration(window.span))
    }
    return text
  }

  static func percent(_ share: Double) -> String {
    (share * 100).formatted(.number.precision(.fractionLength(share < 0.1 ? 2 : 1))) + " %"
  }

  static func color(_ share: Double) -> Color {
    switch share {
    case ..<(IsraAirtimeMath.legalLimit / 2): .green
    case ..<IsraAirtimeMath.legalLimit: .orange
    default: .red
    }
  }

  static func duration(_ seconds: Double) -> String {
    Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
  }
}
