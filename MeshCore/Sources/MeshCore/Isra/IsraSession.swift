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

  /// Tests: a provider seen only by the task tree of `withScopedProvider`, so a test
  /// never leaves process-wide state behind for other suites.
  @TaskLocal static var scopedProvider: HostCapsProvider?

  /// True once the app installed a provider (or a test scoped one).
  public static var isInstalled: Bool {
    currentProvider() != nil
  }

  static func hostCaps(for devicePublicKey: Data) -> IsraProtocol.Caps? {
    currentProvider()?(devicePublicKey)
  }

  private static func currentProvider() -> HostCapsProvider? {
    scopedProvider ?? provider.withLock { $0 }
  }

  /// Tests: runs `operation` with `scoped` installed for its task tree only.
  static func withScopedProvider<R>(
    _ scoped: @escaping HostCapsProvider,
    operation: () async throws -> R
  ) async rethrows -> R {
    try await $scopedProvider.withValue(scoped, operation: operation)
  }
}

/// Outcome of the last HELLO on a session.
public enum IsraHelloState: Sendable, Equatable {
  /// Not sent: no provider installed, or no caps for this device.
  case notSent
  /// Stock firmware (`ERR_CODE_UNSUPPORTED_CMD`): every isra feature stays off.
  case unsupported
  /// Another error or no reply; sent again with the next APP_START.
  case failed
  /// No reply to two HELLOs on a session that never got one: treated as firmware
  /// without the extensions for the rest of the session (no more 3 s waits).
  case gaveUp
  case supported(IsraProtocol.HelloReply, hostCaps: IsraProtocol.Caps)

  /// Caps in effect on the link: host & firmware. SENT_MSGS needs revision 2 or later
  /// (revision 1 used raw frames 30 / 31 / 32, which this build no longer reads).
  public var activeCaps: IsraProtocol.Caps {
    guard case let .supported(reply, hostCaps) = self else { return [] }
    var caps = reply.caps.intersection(hostCaps)
    if reply.revision < IsraProtocol.minimumSentMessagesRevision { caps.remove(.sentMessages) }
    return caps
  }
}

/// Per-session isra state, kept by `MeshCoreSession`.
struct IsraSessionState: Sendable {
  var hello: IsraHelloState = .notSent
  /// HELLOs that timed out on this session.
  var helloTimeouts = 0
  /// A HELLO on this session got a supported reply.
  var everSupported = false
  /// BLE keeps the host caps until the link drops; other links (USB, TCP) clear them on
  /// every APP_START, so HELLO must follow each one. Set by the connection owner.
  var linkKeepsCaps = true
  /// Set once a HELLO on this session negotiated SENT_MSGS. Never cleared during the
  /// session: on BLE the firmware keeps the cap until the link drops, even if a later
  /// HELLO goes unanswered.
  var sentMessagesNegotiated = false
  /// Device state from the HELLO replies and STATE pushes received on this session.
  var live = IsraProtocol.LiveState()
}

public extension MeshCoreSession {
  /// Outcome of the last HELLO on this session.
  var israHello: IsraHelloState {
    isra.hello
  }

  /// Device state flags and advert location policy as the firmware last reported them
  /// (HELLO reply, 0xE1 / 0x11 STATE push), in arrival order. Empty with stock firmware.
  var israLiveState: IsraProtocol.LiveState {
    isra.live
  }

  /// Tells the session whether its link keeps the host caps across APP_START (BLE) or
  /// clears them (USB, TCP): then HELLO follows every APP_START. Only consulted once the
  /// app installed ``IsraHooks``.
  func israSetLinkKeepsCaps(_ keeps: Bool) {
    isra.linkKeepsCaps = keeps
  }

  /// Marks the last HELLO as not in effect (it could not be sent), so the next
  /// APP_START sends it again. No-op when the firmware is unsupported or given up.
  func israInvalidateHello() {
    if case .supported = isra.hello { isra.hello = .failed }
  }

  /// Whether the device-sent message frames (0xE1 / 0x20-0x22) may be processed:
  /// a HELLO on this session negotiated SENT_MSGS. Never true with stock firmware.
  var israSentMessagesActive: Bool {
    isra.sentMessagesNegotiated
  }

  /// Sends HELLO again (for example after the user changed a host cap).
  /// Returns the new state; `.unsupported` and `.gaveUp` are final for the session.
  /// A HELLO that fails leaves the state `.failed`, so the next APP_START retries it.
  @discardableResult
  func israResendHello() async throws -> IsraHelloState {
    guard let key = selfInfo?.publicKey else { return isra.hello }
    try await requestResponseSerializer.withSerialization { [self] in
      await israHelloHoldingSerialization(devicePublicKey: key)
    }
    return isra.hello
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
  /// Every received frame, before parsing: the radio-writes journal tap, and the device
  /// state of HELLO replies and STATE pushes, recorded in arrival order (a STATE push can
  /// overtake the HELLO exchange's own bookkeeping). Inert unless the app installed
  /// ``IsraHooks``.
  func israNoteIncoming(_ data: Data) {
    IsraFrameTap.noteIncoming(data)
    guard data.first == IsraProtocol.code, data.count >= 2, IsraHooks.isInstalled,
          let frame = IsraProtocol.parse(data) else { return }
    isra.live.apply(frame)
  }

  /// HELLO must not wait as long as ordinary commands: it runs inside the connection's
  /// APP_START, which the connection manager bounds to 10 s.
  static let israHelloTimeout: TimeInterval = 3
  /// Unanswered HELLOs before a session that never got a reply gives up.
  static let israHelloMaxTimeouts = 2

  /// APP_START then HELLO in one serialized slot, so no SYNC_NEXT_MESSAGE can slip in between.
  ///
  /// Over BLE the firmware keeps the host caps until the link drops (a later APP_START,
  /// sent after many settings writes, does not clear them), and a session lives for one
  /// link. So HELLO goes only with the session's first APP_START, or again after a HELLO
  /// that got no answer; ``israResendHello()`` sends it on demand. On other links the
  /// firmware clears the caps on every APP_START, so HELLO follows each one.
  func israSendAppStartAndHello(_ appStart: Data) async throws -> SelfInfo {
    try await requestResponseSerializer.withSerialization { [self] in
      let info: SelfInfo = try await sendAndMatchHoldingSerialization(appStart) { event in
        if case let .selfInfo(info) = event { return .success(info) }
        return .ignore
      }
      if await israNeedsHello {
        await israHelloHoldingSerialization(devicePublicKey: info.publicKey)
      }
      return info
    }
  }

  var israNeedsHello: Bool {
    switch isra.hello {
    case .notSent, .failed: true
    case .supported: !isra.linkKeepsCaps
    case .unsupported, .gaveUp: false
    }
  }

  /// The caller holds `requestResponseSerializer`. Never throws: a failed HELLO only
  /// leaves the isra features off.
  func israHelloHoldingSerialization(devicePublicKey: Data) async {
    guard isra.hello != .unsupported, isra.hello != .gaveUp,
          var caps = IsraHooks.hostCaps(for: devicePublicKey) else { return }
    var state = await israExchangeHello(caps)
    // A revision 1 firmware would send device-sent messages as raw frames 30 / 31 / 32,
    // which this build no longer reads: ask again without SENT_MSGS, so it keeps
    // converting them into tagged received messages (the isra2 mirror) instead.
    if case let .supported(reply, _) = state,
       reply.revision < IsraProtocol.minimumSentMessagesRevision, caps.contains(.sentMessages) {
      caps.remove(.sentMessages)
      state = await israExchangeHello(caps)
    }
    guard var state else { return }
    if case .supported = state {
      isra.everSupported = true
      isra.helloTimeouts = 0
    } else if state == .failed, !isra.everSupported, isra.helloTimeouts >= Self.israHelloMaxTimeouts {
      logger.info("isra HELLO: no reply \(self.isra.helloTimeouts) times, extensions off for this session")
      state = .gaveUp
    }
    isra.hello = state
    if state.activeCaps.contains(.sentMessages) { isra.sentMessagesNegotiated = true }
  }

  /// One HELLO round trip. nil on cancellation; a timeout counts in `helloTimeouts`.
  private func israExchangeHello(_ caps: IsraProtocol.Caps) async -> IsraHelloState? {
    do {
      return try await sendAndMatchHoldingSerialization(
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
    } catch is CancellationError {
      return nil
    } catch MeshCoreError.timeout {
      isra.helloTimeouts += 1
      logger.warning("isra HELLO: no reply")
      return .failed
    } catch {
      logger.warning("isra HELLO failed: \(error.localizedDescription)")
      return .failed
    }
  }
}
