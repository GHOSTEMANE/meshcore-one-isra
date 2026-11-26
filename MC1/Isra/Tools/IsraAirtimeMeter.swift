import Foundation
import MC1Services
import MeshCore
import Observation
import OSLog

/// One reading of the local radio's own counters (CMD_GET_STATS core + radio).
/// The firmware reports whole seconds: `tx_air_secs = total_air_time / 1000` and
/// `uptime_secs = millis / 1000`, both since the radio booted.
struct IsraAirtimeSample: Equatable, Sendable {
  let date: Date
  let uptime: UInt32
  let txSeconds: UInt32
  let rxSeconds: UInt32
}

/// TX airtime share over a span of radio uptime.
struct IsraAirtimeWindow: Equatable, Sendable {
  let txSeconds: Double
  let rxSeconds: Double
  /// Radio uptime covered, in seconds.
  let span: Double

  var txShare: Double { span > 0 ? txSeconds / span : 0 }
  var rxShare: Double { span > 0 ? rxSeconds / span : 0 }
  /// Each counter is truncated to whole seconds at both ends: up to 1 s either way.
  var shareUncertainty: Double { span > 0 ? 1 / span : 0 }
}

enum IsraAirtimeMath {
  /// Legal limit in the 869.40-869.65 MHz sub-band (ETSI EN 300 220, ANACOM): 10 %.
  static let legalLimit = 0.10
  /// Shorter spans are too coarse for a percentage (1 s = 1.7 % over a minute).
  static let minimumSpan: Double = 120

  /// Drops samples from before the latest reboot (uptime or counters went back).
  static func currentBoot(_ samples: [IsraAirtimeSample]) -> [IsraAirtimeSample] {
    guard var previous = samples.last else { return [] }
    var kept = [previous]
    for sample in samples.dropLast().reversed() {
      guard sample.uptime <= previous.uptime, sample.txSeconds <= previous.txSeconds,
            sample.rxSeconds <= previous.rxSeconds else { break }
      kept.append(sample)
      previous = sample
    }
    return kept.reversed()
  }

  /// From the oldest sample no more than `maxSpan` before the latest one (same boot).
  static func window(_ samples: [IsraAirtimeSample], maxSpan: Double?) -> IsraAirtimeWindow? {
    let boot = currentBoot(samples)
    guard let latest = boot.last else { return nil }
    let start = boot.first { sample in
      guard let maxSpan else { return true }
      return Double(latest.uptime - sample.uptime) <= maxSpan
    }
    guard let start else { return nil }
    let span = Double(latest.uptime - start.uptime)
    guard span >= minimumSpan else { return nil }
    return IsraAirtimeWindow(
      txSeconds: Double(latest.txSeconds - start.txSeconds),
      rxSeconds: Double(latest.rxSeconds - start.rxSeconds),
      span: span
    )
  }

  /// Since `first` (e.g. the first sample of this connection), if it is in the current boot.
  static func window(_ samples: [IsraAirtimeSample], since first: IsraAirtimeSample?) -> IsraAirtimeWindow? {
    guard let first else { return nil }
    let boot = currentBoot(samples)
    guard boot.contains(first), let latest = boot.last else { return nil }
    let span = Double(latest.uptime - first.uptime)
    guard span >= minimumSpan else { return nil }
    return IsraAirtimeWindow(
      txSeconds: Double(latest.txSeconds - first.txSeconds),
      rxSeconds: Double(latest.rxSeconds - first.rxSeconds),
      span: span
    )
  }

  /// The firmware's counters start at boot, so one sample gives the whole-boot average.
  static func sinceBoot(_ latest: IsraAirtimeSample?) -> IsraAirtimeWindow? {
    guard let latest, Double(latest.uptime) >= minimumSpan else { return nil }
    return IsraAirtimeWindow(
      txSeconds: Double(latest.txSeconds), rxSeconds: Double(latest.rxSeconds), span: Double(latest.uptime)
    )
  }
}

/// Polls the local radio's stats once a minute while connected and keeps the
/// current boot's samples (up to ~2 h) for the airtime card.
@Observable
@MainActor
final class IsraAirtimeMeter {
  static let shared = IsraAirtimeMeter()

  static let pollInterval: Duration = .seconds(60)
  static let keepSpan: UInt32 = 2 * 3600 + 300

  private(set) var samples: [IsraAirtimeSample] = []
  private(set) var connectionStart: IsraAirtimeSample?
  private(set) var unsupported = false
  private(set) var lastError: String?

  private var radioID: UUID?
  private var sessionID: ObjectIdentifier?
  private var loop: Task<Void, Never>?
  private weak var appState: AppState?
  private let logger = Logger(subsystem: "com.mc1", category: "IsraAirtimeMeter")

  func start(appState: AppState) {
    self.appState = appState
    guard loop == nil else { return }
    loop = Task { [weak self] in
      while !Task.isCancelled {
        await self?.poll()
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  var lastHour: IsraAirtimeWindow? { IsraAirtimeMath.window(samples, maxSpan: 3600) }
  var lastTenMinutes: IsraAirtimeWindow? { IsraAirtimeMath.window(samples, maxSpan: 600) }
  var sinceConnect: IsraAirtimeWindow? { IsraAirtimeMath.window(samples, since: connectionStart) }
  var sinceBoot: IsraAirtimeWindow? { IsraAirtimeMath.sinceBoot(samples.last) }
  var latest: IsraAirtimeSample? { samples.last }

  /// Reads the counters now (also called by the card's refresh).
  func poll() async {
    guard let appState, appState.connectionState == .ready,
          let device = appState.connectedDevice, let session = appState.services?.session else { return }
    let currentSession = ObjectIdentifier(session)
    if device.radioID != radioID {
      radioID = device.radioID
      samples = []
      connectionStart = nil
      unsupported = false
    }
    let newConnection = currentSession != sessionID
    sessionID = currentSession
    if newConnection { connectionStart = nil }
    // CMD_GET_STATS is firmware v8+.
    guard device.firmwareVersion >= 8 else {
      unsupported = true
      return
    }
    do {
      let core = try await session.getStatsCore()
      let radio = try await session.getStatsRadio()
      guard device.radioID == radioID else { return }
      let sample = IsraAirtimeSample(
        date: .now, uptime: core.uptimeSeconds, txSeconds: radio.txAirtimeSeconds, rxSeconds: radio.rxAirtimeSeconds
      )
      append(sample)
      if connectionStart == nil || !IsraAirtimeMath.currentBoot(samples).contains(connectionStart!) {
        connectionStart = sample
      }
      lastError = nil
    } catch {
      lastError = error.localizedDescription
      logger.debug("isra airtime poll failed: \(error.localizedDescription)")
    }
  }

  private func append(_ sample: IsraAirtimeSample) {
    samples.append(sample)
    samples = IsraAirtimeMath.currentBoot(samples)
    if let latest = samples.last {
      samples.removeAll { latest.uptime - $0.uptime > Self.keepSpan }
    }
  }
}
