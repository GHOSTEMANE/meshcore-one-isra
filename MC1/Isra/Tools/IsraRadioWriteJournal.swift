import Foundation
import MeshCore
import Observation
import OSLog
import Synchronization

/// One write the app sent to its own radio.
struct IsraRadioWriteEntry: Codable, Identifiable, Sendable, Equatable {
  enum Result: String, Codable, Sendable {
    /// Sent; no reply attributed yet.
    case pending
    case ok
    case error
    /// Refused by the link before it left the phone.
    case notSent
    /// Another write went out before a reply could be attributed to this one.
    case unknown
  }

  let id: UInt64
  let date: Date
  let kind: String
  let what: String
  let change: String?
  /// nil: sent from an app screen. Otherwise an `IsraWriteTrigger` code (automatic path).
  let trigger: String?
  var result: Result
  var detail: String?
}

/// Journal of every frame the app writes to the local radio (settings, contacts,
/// channels, clock, CLI `set`...). Fed by `IsraFrameTap`, kept as a ring buffer of
/// `capacity` entries in Application Support. Never stores coordinates or keys.
final class IsraRadioWriteJournal: Sendable {
  static let shared = IsraRadioWriteJournal()
  static let capacity = 500

  private struct Pending {
    let entryID: UInt64
    let sentAt: Date
    let onSuccess: (@Sendable (inout IsraRadioWriteDecoder.Cache) -> Void)?
  }

  private struct State {
    var decoder = IsraRadioWriteDecoder()
    var entries: [IsraRadioWriteEntry] = []
    var nextID: UInt64 = 1
    var loaded = false
    /// The last non-CLI write still waiting for OK / ERR.
    var pending: Pending?
    /// CLI writes waiting for their tagged reply: tag -> pending.
    var pendingCLI: [String: Pending] = [:]
    /// An untagged CLI write (the CLI tool sends some verbatim).
    var pendingUntaggedCLI: Pending?
    var saveScheduled = false
  }

  private let state = Mutex(State())
  private let fileURL: URL?
  private let ioQueue = DispatchQueue(label: "isra.radio-writes.io", qos: .utility)
  private let onChange: Mutex<(@Sendable () -> Void)?> = Mutex(nil)
  private let logger = Logger(subsystem: "com.mc1", category: "IsraRadioWriteJournal")

  /// A reply later than this is not attributed to a write.
  static let replyWindow: TimeInterval = 15

  init(fileURL: URL? = IsraRadioWriteJournal.defaultFileURL) {
    self.fileURL = fileURL
  }

  static var defaultFileURL: URL? {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
      .appendingPathComponent("isra", isDirectory: true)
      .appendingPathComponent("radio-writes.json")
  }

  // MARK: - Wiring

  /// Installs the frame observers. Safe to call more than once.
  func install() {
    loadIfNeeded()
    IsraFrameTap.install(
      outgoing: { [self] frame, outcome, trigger in
        switch outcome {
        case .sending: noteOutgoing(frame, trigger: trigger)
        case .notSent: noteNotSent(frame)
        }
      },
      incoming: { [self] frame in noteIncoming(frame) }
    )
  }

  func setOnChange(_ handler: (@Sendable () -> Void)?) {
    onChange.withLock { $0 = handler }
  }

  var entries: [IsraRadioWriteEntry] {
    state.withLock { $0.entries }
  }

  func clear() {
    state.withLock {
      $0.entries.removeAll()
      $0.pending = nil
      $0.pendingCLI.removeAll()
      $0.pendingUntaggedCLI = nil
    }
    changed()
  }

  // MARK: - Frames

  func noteOutgoing(_ frame: Data, trigger: String?, now: Date = .now) {
    let didChange: Bool = state.withLock { state in
      expireStale(&state, now: now)
      guard let decoded = state.decoder.decodeOutgoing(frame, now: now) else { return false }
      let entry = IsraRadioWriteEntry(
        id: state.nextID, date: now, kind: decoded.kind, what: decoded.what, change: decoded.change,
        trigger: trigger, result: .pending, detail: nil
      )
      state.nextID += 1
      state.entries.append(entry)
      if state.entries.count > Self.capacity { state.entries.removeFirst(state.entries.count - Self.capacity) }
      let pending = Pending(entryID: entry.id, sentAt: now, onSuccess: decoded.onSuccess)
      if decoded.isCLI {
        if let tag = decoded.cliTag { state.pendingCLI[tag] = pending } else { state.pendingUntaggedCLI = pending }
      } else {
        if let previous = state.pending { setResult(&state, previous.entryID, .unknown) }
        state.pending = pending
      }
      return true
    }
    if didChange { changed() }
  }

  func noteNotSent(_ frame: Data) {
    let didChange: Bool = state.withLock { state in
      // The newest pending entry is the one this frame produced.
      guard let opcode = frame.first else { return false }
      if opcode == CommandCode.runCliCommand.rawValue {
        let (tag, _) = IsraRadioWriteDecoder.splitCLITag(String(decoding: frame.dropFirst(), as: UTF8.self))
        let pending = tag.flatMap { state.pendingCLI.removeValue(forKey: $0) } ?? state.pendingUntaggedCLI
        if tag == nil { state.pendingUntaggedCLI = nil }
        guard let pending else { return false }
        setResult(&state, pending.entryID, .notSent)
        return true
      }
      guard let pending = state.pending else { return false }
      state.pending = nil
      setResult(&state, pending.entryID, .notSent)
      return true
    }
    if didChange { changed() }
  }

  func noteIncoming(_ frame: Data, now: Date = .now) {
    let event = PacketParser.parse(frame)
    let didChange: Bool = state.withLock { state in
      expireStale(&state, now: now)
      var changed = false
      switch event {
      case .ok:
        if let pending = state.pending {
          state.pending = nil
          pending.onSuccess?(&state.decoder.cache)
          setResult(&state, pending.entryID, .ok)
          changed = true
        }
      case let .error(code):
        if let pending = state.pending {
          state.pending = nil
          setResult(&state, pending.entryID, .error, detail: code.map { "ERR \($0)" })
          changed = true
        }
      case let .cliReply(text):
        let (tag, body) = IsraRadioWriteDecoder.splitCLITag(text)
        let pending: Pending? = if let tag {
          state.pendingCLI.removeValue(forKey: tag)
        } else {
          state.pendingUntaggedCLI
        }
        if tag == nil { state.pendingUntaggedCLI = nil }
        if let pending {
          let reply = IsraRadioWriteDecoder.trimmed(body)
          let failed = reply.hasPrefix("Error") || reply.hasPrefix("ERR") || reply == "Unknown command"
          if !failed { pending.onSuccess?(&state.decoder.cache) }
          setResult(&state, pending.entryID, failed ? .error : .ok, detail: failed ? String(reply.prefix(60)) : nil)
          changed = true
        }
      default:
        break
      }
      state.decoder.observeIncoming(event, now: now)
      return changed
    }
    if didChange { changed() }
  }

  // MARK: - Export

  func exportText(_ entries: [IsraRadioWriteEntry]? = nil) -> String {
    let list = entries ?? self.entries
    var lines = [IsraL10n.tr("Isra.Tools.Journal.title")]
    for entry in list.reversed() {
      lines.append(Self.line(entry))
    }
    return lines.joined(separator: "\n")
  }

  static func line(_ entry: IsraRadioWriteEntry) -> String {
    let date = entry.date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon))
    var parts = [date, entry.what]
    if let change = entry.change { parts.append(change) }
    parts.append(triggerLabel(entry.trigger))
    parts.append(resultLabel(entry.result) + (entry.detail.map { " (\($0))" } ?? ""))
    return parts.joined(separator: " · ")
  }

  static func triggerLabel(_ trigger: String?) -> String {
    switch trigger {
    case nil: IsraL10n.tr("Isra.Tools.Journal.Trigger.app")
    case IsraWriteTrigger.clockSync?: IsraL10n.tr("Isra.Tools.Journal.Trigger.clock")
    case IsraWriteTrigger.timezoneSync?: IsraL10n.tr("Isra.Tools.Journal.Trigger.timezone")
    case IsraWriteTrigger.dmRetry?: IsraL10n.tr("Isra.Tools.Journal.Trigger.dmRetry")
    case IsraWriteTrigger.pathRecovery?: IsraL10n.tr("Isra.Tools.Journal.Trigger.pathRecovery")
    case let other?: IsraL10n.tr("Isra.Tools.Journal.Trigger.other", other)
    }
  }

  static func resultLabel(_ result: IsraRadioWriteEntry.Result) -> String {
    IsraL10n.tr("Isra.Tools.Journal.Result.\(result.rawValue)")
  }

  // MARK: - Private

  private func setResult(_ state: inout State, _ id: UInt64, _ result: IsraRadioWriteEntry.Result, detail: String? = nil) {
    guard let index = state.entries.lastIndex(where: { $0.id == id }) else { return }
    state.entries[index].result = result
    state.entries[index].detail = detail
  }

  private func expireStale(_ state: inout State, now: Date) {
    if let pending = state.pending, now.timeIntervalSince(pending.sentAt) > Self.replyWindow {
      state.pending = nil
      setResult(&state, pending.entryID, .unknown)
    }
    for (tag, pending) in state.pendingCLI where now.timeIntervalSince(pending.sentAt) > Self.replyWindow {
      state.pendingCLI[tag] = nil
      setResult(&state, pending.entryID, .unknown)
    }
    if let pending = state.pendingUntaggedCLI, now.timeIntervalSince(pending.sentAt) > Self.replyWindow {
      state.pendingUntaggedCLI = nil
      setResult(&state, pending.entryID, .unknown)
    }
  }

  private func changed() {
    scheduleSave()
    onChange.withLock { $0 }?()
  }

  private func loadIfNeeded() {
    guard let fileURL else { return }
    let alreadyLoaded = state.withLock { state in
      defer { state.loaded = true }
      return state.loaded
    }
    guard !alreadyLoaded else { return }
    guard let data = try? Data(contentsOf: fileURL),
          let stored = try? JSONDecoder().decode([IsraRadioWriteEntry].self, from: data) else { return }
    state.withLock { state in
      // A pending entry from a previous run never got its reply.
      let restored = stored.map { entry -> IsraRadioWriteEntry in
        var entry = entry
        if entry.result == .pending { entry.result = .unknown }
        return entry
      }
      state.entries = Array((restored + state.entries).suffix(Self.capacity))
      state.nextID = (state.entries.map(\.id).max() ?? 0) + 1
    }
  }

  private func scheduleSave() {
    guard let fileURL else { return }
    let shouldSchedule = state.withLock { state in
      defer { state.saveScheduled = true }
      return !state.saveScheduled
    }
    guard shouldSchedule else { return }
    ioQueue.asyncAfter(deadline: .now() + 2) { [self] in
      let snapshot = state.withLock { state in
        state.saveScheduled = false
        return state.entries
      }
      do {
        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
      } catch {
        logger.warning("isra journal save failed: \(error.localizedDescription)")
      }
    }
  }
}

/// Main-actor mirror of the journal for SwiftUI.
@Observable
@MainActor
final class IsraRadioWriteJournalModel {
  static let shared = IsraRadioWriteJournalModel()

  private(set) var entries: [IsraRadioWriteEntry] = []
  private let journal: IsraRadioWriteJournal
  private var refreshQueued = false

  init(journal: IsraRadioWriteJournal = .shared) {
    self.journal = journal
    entries = journal.entries
  }

  func attach() {
    journal.setOnChange { [weak self] in
      Task { @MainActor in self?.queueRefresh() }
    }
    entries = journal.entries
  }

  func clear() {
    journal.clear()
    entries = journal.entries
  }

  func exportText() -> String {
    journal.exportText(entries)
  }

  private func queueRefresh() {
    guard !refreshQueued else { return }
    refreshQueued = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(250))
      refreshQueued = false
      entries = journal.entries
    }
  }
}
