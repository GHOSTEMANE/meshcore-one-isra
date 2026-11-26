import CoreLocation
import MeshCore
import Observation
import os
import UIKit

/// Sends the phone's position to the radio for telemetry (PROTOCOL.md section 2,
/// 0xE1 / 0x01 PHONE_POS), when the radio asks (0xE1 / 0x10) or the phone moved.
///
/// Uses its own `CLLocationManager`, created only when needed (a connection with the
/// cap, a position request, or the settings screen), never on the launch path.
/// Coordinates are never logged nor stored: only the time of the last send.
@MainActor
@Observable
final class IsraPhonePosService: NSObject {
  typealias Sender = @Sendable (Data) async throws -> IsraProtocol.PhonePositionOutcome

  enum Failure: Equatable {
    /// BAD_STATE: "Phone pos", GPS or GPS pwr off on the radio.
    case deviceSetting
    /// ILLEGAL_ARG: accuracy or age refused by the radio.
    case rejected
    case deviceError(UInt8)
    /// No fix from iOS (or no permission).
    case noFix
    /// The iOS fix was too inaccurate (over 1000 m) or too old (over 10 min): not sent.
    case unusableFix
    /// The command did not get an answer.
    case notSent
  }

  /// A cached fix younger than this is sent at once; otherwise a new one is requested.
  static let cachedFixMaxAge: TimeInterval = 120
  /// Significant-change updates are sent at most this often.
  static let movementSendInterval: TimeInterval = 5 * 60
  /// A request right after a send is answered by that send.
  static let duplicateWindow: TimeInterval = 15
  /// After a failure (refusal, no permission, no usable fix, no answer) requests are
  /// not answered for 2, 4, 8, then 15 minutes, instead of a doomed send to every
  /// request (the radio asks once a minute). Reset by a success, a permission change,
  /// a new HELLO or turning the feature on.
  static let backoffBase: TimeInterval = 60
  static let backoffMax: TimeInterval = 15 * 60

  private(set) var authorization: CLAuthorizationStatus = .notDetermined
  private(set) var lastSentAt: Date?
  private(set) var lastFailure: Failure?
  private(set) var isBound = false
  /// Requests are not answered before this time (after a failure).
  private(set) var backoffUntil: Date?

  @ObservationIgnored private var manager: CLLocationManager?
  @ObservationIgnored private var sender: Sender?
  @ObservationIgnored private var pendingRequest = false
  @ObservationIgnored private var wantsAlways = false
  @ObservationIgnored private var monitoringSignificantChanges = false
  @ObservationIgnored private var isSending = false
  @ObservationIgnored private var backoffStep = 0
  @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  @ObservationIgnored private var backgroundTimeout: Task<Void, Never>?

  @ObservationIgnored private let logger = Logger(subsystem: "com.mc1", category: "IsraPhonePos")

  // MARK: - Permission

  /// Reads the current authorization (creates the location manager).
  func refreshAuthorization() {
    authorization = ensureManager().authorizationStatus
  }

  /// When-In-Use first, then Always, as iOS requires. Returns false when only the
  /// iOS Settings app can change it now.
  @discardableResult
  func requestAlwaysAuthorization() -> Bool {
    let manager = ensureManager()
    switch manager.authorizationStatus {
    case .notDetermined:
      wantsAlways = true
      manager.requestWhenInUseAuthorization()
      return true
    case .authorizedWhenInUse:
      manager.requestAlwaysAuthorization()
      return true
    default:
      return false
    }
  }

  // MARK: - Connection

  /// The link has the PHONE_POS cap: answer requests and send once now.
  func bind(sender: @escaping Sender, sendNow: Bool) {
    self.sender = sender
    isBound = true
    refreshAuthorization()
    updateSignificantChangeMonitoring()
    if sendNow {
      handlePositionRequest()
    }
  }

  /// The link dropped or the cap went away.
  func unbind() {
    sender = nil
    isBound = false
    pendingRequest = false
    updateSignificantChangeMonitoring()
    endBackgroundTask()
  }

  /// 0xE1 / 0x10 from the radio (also used once after HELLO).
  func handlePositionRequest() {
    guard sender != nil else { return }
    if let lastSentAt, Date().timeIntervalSince(lastSentAt) < Self.duplicateWindow { return }
    if let backoffUntil, Date() < backoffUntil { return }
    let manager = ensureManager()
    if let cached = manager.location, Self.isUsable(cached, maxAge: Self.cachedFixMaxAge) {
      beginBackgroundTask()
      send(cached)
      return
    }
    // No permission, or When-In-Use while in the background: iOS gives no fix.
    let status = manager.authorizationStatus
    let inBackground = UIApplication.shared.applicationState == .background
    guard status == .authorizedAlways || (status == .authorizedWhenInUse && !inBackground) else {
      fail(.noFix)
      return
    }
    beginBackgroundTask()
    pendingRequest = true
    manager.requestLocation()
  }

  /// Answers the next request at once (feature turned on, new HELLO).
  func resetBackoff() {
    backoffStep = 0
    backoffUntil = nil
  }

  // MARK: - Location manager

  private func ensureManager() -> CLLocationManager {
    if let manager { return manager }
    let manager = CLLocationManager()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    self.manager = manager
    authorization = manager.authorizationStatus
    return manager
  }

  private func updateSignificantChangeMonitoring() {
    guard let manager else { return }
    let wanted = sender != nil && manager.authorizationStatus == .authorizedAlways
      && CLLocationManager.significantLocationChangeMonitoringAvailable()
    guard wanted != monitoringSignificantChanges else { return }
    monitoringSignificantChanges = wanted
    if wanted {
      manager.startMonitoringSignificantLocationChanges()
    } else {
      manager.stopMonitoringSignificantLocationChanges()
    }
  }

  private func didUpdate(_ location: CLLocation) {
    if pendingRequest {
      pendingRequest = false
      // The radio refuses over 1000 m or over 10 min (ILLEGAL_ARG): do not send those.
      guard Self.isUsable(location, maxAge: TimeInterval(IsraProtocol.maxAgeSeconds)) else {
        fail(.unusableFix)
        return
      }
      send(location)
      return
    }
    // Significant change while connected.
    guard sender != nil, Self.isUsable(location, maxAge: Self.cachedFixMaxAge) else { return }
    if let lastSentAt, Date().timeIntervalSince(lastSentAt) < Self.movementSendInterval { return }
    if let backoffUntil, Date() < backoffUntil { return }
    beginBackgroundTask()
    send(location)
  }

  private func didFail() {
    guard pendingRequest else { return }
    pendingRequest = false
    fail(.noFix)
  }

  private func didChangeAuthorization(_ status: CLAuthorizationStatus) {
    if status != authorization { resetBackoff() }
    authorization = status
    if wantsAlways, status == .authorizedWhenInUse {
      wantsAlways = false
      manager?.requestAlwaysAuthorization()
    }
    updateSignificantChangeMonitoring()
  }

  // MARK: - Sending

  private func send(_ location: CLLocation) {
    // A send in flight answers this request too, and ends the background task itself.
    guard !isSending else { return }
    guard let sender else {
      endBackgroundTask()
      return
    }
    let age = max(0, Int(Date().timeIntervalSince(location.timestamp).rounded()))
    guard let frame = IsraProtocol.phonePosition(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
      horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
      ageSeconds: age
    ) else {
      fail(.noFix)
      return
    }
    let accuracy = Int(location.horizontalAccuracy.rounded())
    isSending = true
    Task {
      defer {
        isSending = false
        endBackgroundTask()
      }
      do {
        let outcome = try await sender(frame)
        switch outcome {
        case .accepted:
          lastSentAt = Date()
          lastFailure = nil
          resetBackoff()
          logger.info("phone position sent (age \(age) s, accuracy \(accuracy) m)")
        case .badState:
          fail(.deviceSetting)
        case .illegalArgument:
          fail(.rejected)
        case let .deviceError(code):
          fail(.deviceError(code))
        }
      } catch {
        fail(.notSent)
      }
    }
  }

  /// Records a failure and backs off: 2, 4, 8, then 15 minutes.
  private func fail(_ failure: Failure) {
    lastFailure = failure
    backoffStep += 1
    let delay = min(Self.backoffBase * pow(2, Double(min(backoffStep, 10))), Self.backoffMax)
    backoffUntil = Date().addingTimeInterval(delay)
    logger.info("phone position not sent, next answer in \(Int(delay)) s")
    endBackgroundTask()
  }

  private static func isUsable(_ location: CLLocation, maxAge: TimeInterval) -> Bool {
    location.horizontalAccuracy >= 0
      && location.horizontalAccuracy <= IsraProtocol.maxAccuracyMeters
      && Date().timeIntervalSince(location.timestamp) < maxAge
  }

  // MARK: - Background time

  /// A BLE wake gives a few seconds; ask for enough to get a fix and send it.
  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "isra.phonePos") { [weak self] in
      MainActor.assumeIsolated { self?.endBackgroundTask() }
    }
    backgroundTimeout?.cancel()
    backgroundTimeout = Task { [weak self] in
      try? await Task.sleep(for: .seconds(25))
      guard !Task.isCancelled else { return }
      self?.pendingRequest = false
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    backgroundTimeout?.cancel()
    backgroundTimeout = nil
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }
}

// MARK: - CLLocationManagerDelegate

/// The manager is created on the main thread, so its callbacks arrive there.
extension IsraPhonePosService: CLLocationManagerDelegate {
  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last else { return }
    MainActor.assumeIsolated { didUpdate(location) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    MainActor.assumeIsolated { didFail() }
  }

  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    MainActor.assumeIsolated { didChangeAuthorization(status) }
  }
}
