import Foundation
import Synchronization

// isra: observation points for the isra fork's tools (radio-writes journal).
// Inert unless the app installs observers: no behaviour change otherwise.
// The package cannot see the app target's ISRA compilation condition, so the
// hooks that call into this file are plain calls marked `// isra:`.

/// Why the app is writing to the radio when it is not a direct user action.
/// Automatic paths wrap their writes in `IsraWriteTrigger.$current.withValue("clock") { ... }`.
/// Unstructured tasks inherit the value, so it survives the session's request serializer.
public enum IsraWriteTrigger {
  @TaskLocal public static var current: String?

  public static let clockSync = "clock"
  public static let timezoneSync = "timezone"
  public static let dmRetry = "dmRetry"
  public static let pathRecovery = "pathRecovery"
}

/// Frames the session hands to the transport and frames it receives.
public enum IsraFrameTap {
  public enum Outcome: Sendable {
    /// About to be written to the transport.
    case sending
    /// The transport refused it before submission: it never reached the radio.
    case notSent
  }

  public typealias Outgoing = @Sendable (_ frame: Data, _ outcome: Outcome, _ trigger: String?) -> Void
  public typealias Incoming = @Sendable (_ frame: Data) -> Void

  private struct Observers {
    var outgoing: Outgoing?
    var incoming: Incoming?
  }

  private static let observers = Mutex(Observers())

  public static func install(outgoing: Outgoing?, incoming: Incoming?) {
    observers.withLock { $0 = Observers(outgoing: outgoing, incoming: incoming) }
  }

  static func noteOutgoing(_ frame: Data, _ outcome: Outcome = .sending) {
    guard let observer = observers.withLock({ $0.outgoing }) else { return }
    observer(frame, outcome, IsraWriteTrigger.current)
  }

  static func noteIncoming(_ frame: Data) {
    guard let observer = observers.withLock({ $0.incoming }) else { return }
    observer(frame)
  }
}
