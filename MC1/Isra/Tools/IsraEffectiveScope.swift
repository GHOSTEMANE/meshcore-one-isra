import MC1Services
import MeshCore
import SwiftUI

/// The flood scope a channel message will really go out with.
///
/// Mirrors `MessageService.sendChannelMessageWithScope` + `ChannelFloodScopeResolver`:
/// a per-send scope the app sets (CMD_SET_FLOOD_SCOPE_KEY) wins over anything on the
/// radio (firmware `sendFloodScoped`, MyMesh.cpp); a zero key leaves the choice to the
/// radio: upstream firmware uses its default scope, the Solo uses the scope chosen for
/// that channel on the device (else its default). The app cannot read the Solo's
/// per-channel choice, so it says so instead of guessing.
enum IsraEffectiveScope: Equatable {
  /// The app sets this region for each send.
  case appRegion(String)
  /// The app forces an unscoped flood.
  case appUnscoped
  /// The app sends a zero key (or nothing on firmware < 8): the radio decides.
  case radio(defaultName: String?)

  static func resolve(
    channelScope: ChannelFloodScope,
    supportsUnscopedFloodSend: Bool,
    defaultScopeName: String?
  ) -> IsraEffectiveScope {
    switch ChannelFloodScopeResolver.resolve(
      channelFloodScope: channelScope, supportsUnscopedFloodSend: supportsUnscopedFloodSend
    ) {
    case .unscoped:
      return .appUnscoped
    case let .scope(scope):
      if case let .region(name) = scope { return .appRegion(name) }
      let name = defaultScopeName.flatMap { $0.isEmpty ? nil : $0 }
      return .radio(defaultName: name)
    }
  }

  var label: String {
    switch self {
    case let .appRegion(name): IsraL10n.tr("Isra.Tools.Scope.appRegion", name)
    case .appUnscoped: IsraL10n.tr("Isra.Tools.Scope.appUnscoped")
    case let .radio(name?): IsraL10n.tr("Isra.Tools.Scope.radioDefault", name)
    case .radio(nil): IsraL10n.tr("Isra.Tools.Scope.radio")
    }
  }

  var explanation: String {
    switch self {
    case .appRegion: IsraL10n.tr("Isra.Tools.Scope.appRegionHelp")
    case .appUnscoped: IsraL10n.tr("Isra.Tools.Scope.appUnscopedHelp")
    case .radio: IsraL10n.tr("Isra.Tools.Scope.radioHelp")
    }
  }
}

/// Small line above the channel composer: which scope this message will use.
struct IsraEffectiveScopeLabel: View {
  @Environment(\.appState) private var appState
  let channel: ChannelDTO
  @State private var expanded = false

  var body: some View {
    if let device = appState.connectedDevice {
      let scope = IsraEffectiveScope.resolve(
        channelScope: channel.floodScope,
        supportsUnscopedFloodSend: device.supportsUnscopedFloodSend,
        defaultScopeName: device.defaultFloodScopeName
      )
      Button {
        expanded.toggle()
      } label: {
        VStack(alignment: .leading, spacing: 2) {
          Label(scope.label, systemImage: "scope")
            .font(.caption2)
          if expanded {
            Text(scope.explanation)
              .font(.caption2)
              .multilineTextAlignment(.leading)
          }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 2)
      }
      .buttonStyle(.plain)
      .accessibilityHint(scope.explanation)
    }
  }
}

extension View {
  /// isra: puts the effective-scope line above a channel composer.
  func israEffectiveScope(_ channel: ChannelDTO) -> some View {
    VStack(spacing: 2) {
      IsraEffectiveScopeLabel(channel: channel)
      self
    }
  }
}
