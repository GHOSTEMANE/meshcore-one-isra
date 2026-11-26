import CryptoKit
import Foundation
import MeshCore

/// Messages composed on the radio itself (isra/PROTOCOL.md revision 2, section 3:
/// 0xE1 / 0x20 SENT_DM, 0x21 SENT_CHANNEL, 0x22 SENT_STATUS).
///
/// They reach the session as replies to `CMD_SYNC_NEXT_MESSAGE` during the message drain
/// (the drain skips them and fetches the next one); this service stores them as
/// **outgoing** messages in the right conversation, with no notification, no unread
/// count and no last-heard update, and follows their delivery:
/// - SENT_DM: status bytes, and the ACK codes derived for attempts 0-3, so a live
///   `PUSH_CODE_SEND_CONFIRMED` (0x82) marks it delivered;
/// - SENT_CHANNEL: stored with the same timestamp and body the radio put on air,
///   so heard repeats attach as for the app's own posts;
/// - SENT_STATUS: delivered (with round trip), retrying or failed.
///
/// Frames are processed only when a HELLO on this session negotiated SENT_MSGS
/// (revision 2 or later); with stock firmware nothing is ever processed.
actor IsraSentMessageService {
  /// Device-sent DMs carry attempts 0-3 (the radio's own resends, same timestamp).
  static let attemptCount: UInt8 = 4
  static let dedupPrefixDM = "isra.sent.dm."
  static let dedupPrefixChannel = "isra.sent.ch."

  private let session: MeshCoreSession
  private let dataStore: PersistenceStore
  private let messageService: MessageService
  private let syncCoordinator: SyncCoordinator
  private let rxLogService: RxLogService
  private let heardRepeatsService: HeardRepeatsService
  private let receiveLifetime: ReceiveScope.Lifetime
  private let radioID: UUID
  /// True once the session's HELLO negotiated SENT_MSGS.
  private let isNegotiated: @Sendable () async -> Bool
  private let logger = PersistentLogger(subsystem: "com.mc1", category: "IsraSentMessages")

  private var task: Task<Void, Never>?
  private var subscriptionID: UUID?
  /// Expected ACK code -> message (live 0x82).
  private var ackCodes: [Data: UUID] = [:]
  /// Recipient prefix + timestamp -> message (SENT_STATUS).
  private var messagesByKey: [String: UUID] = [:]

  init(
    session: MeshCoreSession,
    dataStore: PersistenceStore,
    messageService: MessageService,
    syncCoordinator: SyncCoordinator,
    rxLogService: RxLogService,
    heardRepeatsService: HeardRepeatsService,
    receiveLifetime: ReceiveScope.Lifetime,
    radioID: UUID,
    isNegotiated: (@Sendable () async -> Bool)? = nil
  ) {
    self.session = session
    self.dataStore = dataStore
    self.messageService = messageService
    self.syncCoordinator = syncCoordinator
    self.rxLogService = rxLogService
    self.heardRepeatsService = heardRepeatsService
    self.receiveLifetime = receiveLifetime
    self.radioID = radioID
    self.isNegotiated = isNegotiated ?? { [session] in await session.israSentMessagesActive }
  }

  // MARK: - Lifecycle

  /// Subscribes before the first drain so no frame is missed.
  func start() async {
    guard task == nil else { return }
    let filter = EventFilter { event in
      if case .acknowledgement = event { return true }
      switch IsraProtocol.frame(from: event) {
      case .sentContactMessage?, .sentChannelMessage?, .sentMessageStatus?: return true
      default: return false
      }
    }
    let (id, stream) = await session.eventsTracked(filter: filter)
    subscriptionID = id
    task = Task { [weak self] in
      for await event in stream {
        guard let self, !Task.isCancelled else { break }
        await handle(event)
      }
    }
  }

  func stop() async {
    let worker = task
    task = nil
    worker?.cancel()
    if let subscriptionID {
      await session.finishEvents(id: subscriptionID)
    }
    subscriptionID = nil
    await worker?.value
  }

  // MARK: - Events

  private func handle(_ event: MeshEvent) async {
    if case let .acknowledgement(code, tripTime) = event {
      await handleAcknowledgement(code: code, tripTime: tripTime)
      return
    }
    guard await isNegotiated() else {
      logger.warning("isra: device-sent message frame without SENT_MSGS negotiated, ignored")
      return
    }
    switch IsraProtocol.frame(from: event) {
    case let .sentContactMessage(message)?:
      await storeDirectMessage(message)
    case let .sentChannelMessage(message)?:
      await storeChannelMessage(message)
    case let .sentMessageStatus(status)?:
      await applyStatusFrame(status)
    default:
      break
    }
  }

  // MARK: - SENT_DM

  private func storeDirectMessage(_ frame: IsraProtocol.SentContactMessage) async {
    do {
      guard let scope = try await dataStore.captureReceiveScope(radioID: radioID, link: receiveLifetime),
            scope.isCurrent else { return }
      guard let contact = try await dataStore.fetchContact(radioID: radioID, publicKeyPrefix: frame.recipientPrefix) else {
        logger.warning("isra: device-sent DM for an unknown contact, not stored")
        return
      }
      let key = Self.messageKey(prefix: frame.recipientPrefix, timestamp: frame.timestamp)
      let dedupKey = Self.dedupPrefixDM + key + "." + Self.textDigest(frame.text)
      if let existing = try await dataStore.fetchMessage(deduplicationKey: dedupKey, radioID: radioID) {
        messagesByKey[key] = existing.id
        await registerAckCodes(for: existing.id, timestamp: frame.timestamp, text: frame.text)
        await apply(frame.status, attempt: frame.attempt, roundTrip: nil, ackCode: nil, to: existing.id)
        return
      }

      let now = Date()
      let message = Message(
        radioID: radioID,
        contactID: contact.id,
        text: frame.text,
        timestamp: frame.timestamp,
        createdAt: now,
        sortDate: Self.sortDate(timestamp: frame.timestamp, arrival: now),
        directionRawValue: MessageDirection.outgoing.rawValue,
        statusRawValue: MessageStatus.sent.rawValue,
        textTypeRawValue: (TextType(rawValue: frame.textType) ?? .plain).rawValue,
        isRead: true,
        deduplicationKey: dedupKey
      )
      let dto = MessageDTO(from: message)
      try await dataStore.saveMessage(dto)
      guard scope.isCurrent else { return }
      messagesByKey[key] = dto.id
      await registerAckCodes(for: dto.id, timestamp: frame.timestamp, text: frame.text)
      try? await dataStore.updateContactLastMessage(contactID: contact.id, date: now)
      syncCoordinator.dataEventBroadcaster.yield(.directMessageReceived(message: dto, contact: contact, scope: scope))
      await syncCoordinator.notifyConversationsChanged(scope: scope)
      if frame.status != .sent {
        await apply(frame.status, attempt: frame.attempt, roundTrip: nil, ackCode: nil, to: dto.id)
      }
    } catch {
      logger.error("isra: storing a device-sent DM failed: \(error.localizedDescription)")
    }
  }

  private func registerAckCodes(for messageID: UUID, timestamp: UInt32, text: String) async {
    guard let senderKey = await session.currentSelfInfo?.publicKey else { return }
    if ackCodes.count > 512 { ackCodes.removeAll() }
    for attempt in 0..<Self.attemptCount {
      let code = AckCodeBuilder.expectedAck(
        timestamp: timestamp, attempt: attempt, text: text, senderPublicKey: senderKey
      )
      ackCodes[code] = messageID
    }
  }

  // MARK: - SENT_CHANNEL

  private func storeChannelMessage(_ frame: IsraProtocol.SentChannelMessage) async {
    do {
      guard let scope = try await dataStore.captureReceiveScope(radioID: radioID, link: receiveLifetime),
            scope.isCurrent else { return }
      let dedupKey = Self.dedupPrefixChannel + "\(frame.channelIndex).\(frame.timestamp)." + Self.textDigest(frame.text)
      if try await dataStore.fetchMessage(deduplicationKey: dedupKey, radioID: radioID) != nil { return }
      if try await dataStore.findSentChannelMessage(
        radioID: radioID, channelIndex: frame.channelIndex, timestamp: frame.timestamp, text: frame.text
      ) != nil { return }

      let now = Date()
      let message = Message(
        radioID: radioID,
        channelIndex: frame.channelIndex,
        text: frame.text,
        timestamp: frame.timestamp,
        createdAt: now,
        sortDate: Self.sortDate(timestamp: frame.timestamp, arrival: now),
        directionRawValue: MessageDirection.outgoing.rawValue,
        statusRawValue: MessageStatus.sent.rawValue,
        textTypeRawValue: (TextType(rawValue: frame.textType) ?? .plain).rawValue,
        isRead: true,
        deduplicationKey: dedupKey
      )
      let dto = MessageDTO(from: message)
      try await dataStore.saveMessage(dto)
      guard scope.isCurrent else { return }
      if let channel = try? await dataStore.fetchChannel(radioID: radioID, index: frame.channelIndex) {
        try? await dataStore.updateChannelLastMessage(channelID: channel.id, date: now)
      }
      // Repeats heard before this frame arrived are already in the RX log.
      await attachEarlierRepeats(channelIndex: frame.channelIndex, timestamp: frame.timestamp)
      let current = (try? await dataStore.fetchMessage(id: dto.id)) ?? dto
      syncCoordinator.dataEventBroadcaster.yield(.channelMessageReceived(
        message: current, channelIndex: frame.channelIndex, scope: scope
      ))
      await syncCoordinator.notifyConversationsChanged(scope: scope)
    } catch {
      logger.error("isra: storing a device-sent channel message failed: \(error.localizedDescription)")
    }
  }

  private func attachEarlierRepeats(channelIndex: UInt8, timestamp: UInt32) async {
    guard let raw = try? await dataStore.fetchRxLogEntries(
      radioID: radioID, channelIndex: channelIndex, senderTimestamp: timestamp
    ), !raw.isEmpty else { return }
    for entry in await rxLogService.decodedEntries(raw) {
      await heardRepeatsService.processForRepeats(entry)
    }
  }

  // MARK: - SENT_STATUS and live ACK

  private func applyStatusFrame(_ frame: IsraProtocol.SentMessageStatus) async {
    let key = Self.messageKey(prefix: frame.recipientPrefix, timestamp: frame.timestamp)
    var messageID = messagesByKey[key]
    if messageID == nil {
      messageID = await findStoredDirectMessage(prefix: frame.recipientPrefix, timestamp: frame.timestamp)
    }
    guard let messageID else { return } // a SENT_STATUS for an unknown message is ignored
    messagesByKey[key] = messageID
    var ackCode: Data?
    if frame.status == .delivered, let message = try? await dataStore.fetchMessage(id: messageID),
       let senderKey = await session.currentSelfInfo?.publicKey {
      ackCode = AckCodeBuilder.expectedAck(
        timestamp: frame.timestamp, attempt: frame.attempt % Self.attemptCount,
        text: message.text, senderPublicKey: senderKey
      )
    }
    await apply(
      frame.status, attempt: frame.attempt,
      roundTrip: frame.status == .delivered ? frame.roundTripMs : nil,
      ackCode: ackCode, to: messageID
    )
  }

  private func findStoredDirectMessage(prefix: Data, timestamp: UInt32) async -> UUID? {
    guard let contact = try? await dataStore.fetchContact(radioID: radioID, publicKeyPrefix: prefix),
          let recent = try? await dataStore.fetchMessages(contactID: contact.id, limit: 200, offset: 0) else { return nil }
    let keyPrefix = Self.dedupPrefixDM + Self.messageKey(prefix: prefix, timestamp: timestamp) + "."
    return recent.first { $0.deduplicationKey?.hasPrefix(keyPrefix) == true }?.id
  }

  private func handleAcknowledgement(code: Data, tripTime: UInt32?) async {
    guard let messageID = ackCodes[code] else { return }
    await apply(.delivered, attempt: 0, roundTrip: tripTime, ackCode: code, to: messageID)
  }

  // MARK: - Status

  private func apply(
    _ status: IsraProtocol.SentStatus,
    attempt: UInt8,
    roundTrip: UInt32?,
    ackCode: Data?,
    to messageID: UUID
  ) async {
    do {
      guard let current = try await dataStore.fetchMessage(id: messageID) else { return }
      switch status {
      case .sent:
        return
      case .delivered:
        guard current.status != .delivered else { return }
        if current.status == .failed {
          try await dataStore.updateMessageStatus(id: messageID, status: .delivered)
        }
        try await dataStore.updateMessageAck(
          id: messageID, ackCode: ackCode?.ackCodeUInt32 ?? current.ackCode ?? 0,
          status: .delivered, roundTripTime: roundTrip
        )
        ackCodes = ackCodes.filter { $0.value != messageID }
        messageService.statusEventBroadcaster.yield(.statusResolved(
          messageID: messageID, status: .delivered, roundTripTime: roundTrip
        ))
      case .retrying:
        guard current.status != .delivered, current.status != .failed else { return }
        let maxAttempts = Int(Self.attemptCount) - 1
        try await dataStore.updateMessageRetryStatus(
          id: messageID, status: .retrying, retryAttempt: Int(attempt), maxRetryAttempts: maxAttempts
        )
        messageService.statusEventBroadcaster.yield(.retrying(
          messageID: messageID, attempt: Int(attempt), maxAttempts: maxAttempts
        ))
      case .failed:
        guard try await dataStore.updateMessageStatusUnlessDelivered(id: messageID, status: .failed) else { return }
        messageService.statusEventBroadcaster.yield(.failed(messageID: messageID))
      }
    } catch {
      logger.error("isra: updating a device-sent message failed: \(error.localizedDescription)")
    }
  }

  // MARK: - Helpers

  static func messageKey(prefix: Data, timestamp: UInt32) -> String {
    "\(prefix.hexString).\(timestamp)"
  }

  static func textDigest(_ text: String) -> String {
    Data(SHA256.hash(data: Data(text.utf8)).prefix(8)).hexString
  }

  /// The radio's timestamp when plausible (clock set, not in the future), else arrival time.
  static func sortDate(timestamp: UInt32, arrival: Date) -> Date {
    let sent = Date(timeIntervalSince1970: TimeInterval(timestamp))
    let plausible = sent <= arrival.addingTimeInterval(60)
      && sent >= arrival.addingTimeInterval(-7 * 24 * 3600)
    return plausible ? min(sent, arrival) : arrival
  }
}
