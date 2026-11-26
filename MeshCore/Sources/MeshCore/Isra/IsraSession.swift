import Foundation
import Synchronization

/// App-installed switches for the isra protocol extensions.
///
/// The package cannot see the app's `ISRA` compilation condition, so every isra
/// behaviour in it is off until the app installs a host-caps provider. With no
/// provider (upstream app, tests) the session never sends HELLO.
public enum IsraHooks {
  public typealias HostCapsProvider = @Sendable (_ devicePublicKey: Data) -> IsraProtocol.Caps?

  private static let provider = Mutex<HostCapsProvider?>(nil)

  /// Installs (or removes, with nil) the provider of host caps for a device.
  /// Returning nil for a device skips HELLO on that connection.
  public static func setHostCapsProvider(_ newValue: HostCapsProvider?) {
    provider.withLock { $0 = newValue }
  }

  /// True once the app installed a provider.
  public static var isInstalled: Bool {
    provider.withLock { $0 != nil }
  }

  static func hostCaps(for devicePublicKey: Data) -> IsraProtocol.Caps? {
    let current = provider.withLock { $0 }
    return current?(devicePublicKey)
  }
}

/// Outcome of the last HELLO on a session.
public enum IsraHelloState: Sendable, Equatable {
  /// Not sent: no provider installed, or no caps for this device.
  case notSent
  /// Stock firmware (`ERR_CODE_UNSUPPORTED_CMD`): every isra feature stays off.
  case unsupported
  /// Another error or no reply.
  case failed
  case supported(IsraProtocol.HelloReply, hostCaps: IsraProtocol.Caps)

  /// Caps in effect on the link: host & firmware.
  public var activeCaps: IsraProtocol.Caps {
    if case let .supported(reply, hostCaps) = self { return reply.caps.intersection(hostCaps) }
    return []
  }
}

public extension MeshCoreSession {
  /// Outcome of the last HELLO on this session.
  var israHello: IsraHelloState {
    israHelloState
  }

  /// Sends HELLO again (for example after the user changed a host cap).
  /// Returns the new state; `.unsupported` is final for the session.
  @discardableResult
  func israResendHello() async throws -> IsraHelloState {
    guard let key = selfInfo?.publicKey else { return israHelloState }
    try await requestResponseSerializer.withSerialization { [self] in
      await israHelloHoldingSerialization(devicePublicKey: key)
    }
    return israHelloState
  }

  /// Sends PHONE_POS (built with ``IsraProtocol/phonePosition(latitude:longitude:altitudeMeters:horizontalAccuracy:ageSeconds:)``).
  func israSendPhonePosition(_ frame: Data) async throws -> IsraProtocol.PhonePositionOutcome {
    try await sendAndMatch(frame) { event in
      switch event {
      case .ok(value: nil):
        return .success(.accepted)
      case let .error(code):
        switch code.flatMap(ErrorCode.init(rawValue:)) {
        case .badState: return .success(.badState)
        case .illegalArgument: return .success(.illegalArgument)
        default: return .success(.deviceError(code ?? 0))
        }
      default:
        return .ignore
      }
    }
  }
}

extension MeshCoreSession {
  /// HELLO must not wait as long as ordinary commands: it runs inside the connection's
  /// APP_START, which the connection manager bounds to 10 s.
  static let israHelloTimeout: TimeInterval = 3

  /// APP_START then HELLO in one serialized slot, so no SYNC_NEXT_MESSAGE can slip in between
  /// (APP_START clears the caps on the firmware).
  func israSendAppStartAndHello(_ appStart: Data) async throws -> SelfInfo {
    try await requestResponseSerializer.withSerialization { [self] in
      let info: SelfInfo = try await sendAndMatchHoldingSerialization(appStart) { event in
        if case let .selfInfo(info) = event { return .success(info) }
        return .ignore
      }
      await israHelloHoldingSerialization(devicePublicKey: info.publicKey)
      return info
    }
  }

  /// The caller holds `requestResponseSerializer`. Never throws: a failed HELLO only
  /// leaves the isra features off.
  func israHelloHoldingSerialization(devicePublicKey: Data) async {
    guard israHelloState != .unsupported,
          let caps = IsraHooks.hostCaps(for: devicePublicKey) else { return }
    do {
      let state: IsraHelloState = try await sendAndMatchHoldingSerialization(
        IsraProtocol.hello(hostCaps: caps),
        timeout: min(Self.israHelloTimeout, configuration.defaultTimeout)
      ) { event in
        switch event {
        case .parseFailure:
          if case let .helloReply(reply)? = IsraProtocol.frame(from: event) {
            return .success(.supported(reply, hostCaps: caps))
          }
          return .ignore
        case let .error(code):
          return .success(code == ErrorCode.unsupportedCommand.rawValue ? .unsupported : .failed)
        default:
          return .ignore
        }
      }
      israHelloState = state
    } catch is CancellationError {
      return
    } catch {
      logger.warning("isra HELLO failed: \(error.localizedDescription)")
      israHelloState = .failed
    }
  }
}
