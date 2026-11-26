import Foundation

/// isra companion protocol extensions, revision 2 (see `isra/PROTOCOL.md`).
///
/// One private opcode, 0xE1, with a sub-op byte, for commands, replies and pushes,
/// including the device-sent message frames (sub-ops 0x20 / 0x21 / 0x22, revision 2).
/// Stock firmware answers 0xE1 with `ERR_CODE_UNSUPPORTED_CMD` and never sends any
/// of these frames.
public enum IsraProtocol {
  /// Opcode of every isra command, reply and push.
  public static let code: UInt8 = 0xE1
  /// Protocol revision this build understands.
  public static let revision: UInt8 = 2
  /// Oldest firmware revision whose device-sent message frames this build reads.
  /// Revision 1 sent them as raw frames 30 / 31 / 32, which this build ignores.
  public static let minimumSentMessagesRevision: UInt8 = 2

  /// Sub-op byte after ``code``.
  public enum SubOp: UInt8, Sendable {
    case hello = 0x00
    case phonePosition = 0x01
    case positionRequest = 0x10
    /// Device state push: flags and advert location policy, on every change.
    case state = 0x11
    /// Device-sent messages (section 3), replies to `CMD_SYNC_NEXT_MESSAGE`.
    case sentContactMessage = 0x20
    case sentChannelMessage = 0x21
    case sentMessageStatus = 0x22
  }

  /// Capability bits shared by host and firmware (HELLO).
  public struct Caps: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// SENT_DM / SENT_CHANNEL / SENT_STATUS (messages sent from the device).
    public static let sentMessages = Caps(rawValue: 1 << 0)
    /// Position requests answered with PHONE_POS.
    public static let phonePosition = Caps(rawValue: 1 << 1)
  }

  /// Device state flags in the HELLO reply and the STATE push.
  public struct DeviceState: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// "Phone pos" setting on the device.
    public static let phonePositionSetting = DeviceState(rawValue: 1 << 0)
    /// GPS master switch.
    public static let gpsOn = DeviceState(rawValue: 1 << 1)
    /// GPS duty cycle ("GPS pwr").
    public static let gpsDutyCycle = DeviceState(rawValue: 1 << 2)
  }

  /// Firmware reply to HELLO.
  public struct HelloReply: Sendable, Equatable {
    public let caps: Caps
    public let revision: UInt8
    public let state: DeviceState
    /// Byte [8], advert location policy as in SELF_INFO. nil when the reply is shorter
    /// (firmware from before the byte was appended).
    public let advertPolicy: UInt8?

    public init(caps: Caps, revision: UInt8, state: DeviceState, advertPolicy: UInt8? = nil) {
      self.caps = caps
      self.revision = revision
      self.state = state
      self.advertPolicy = advertPolicy
    }
  }

  /// The device state the firmware last reported on this link (HELLO reply, STATE push),
  /// in arrival order. nil fields are unknown: the app falls back to SELF_INFO.
  public struct LiveState: Sendable, Equatable {
    public var flags: DeviceState?
    public var advertPolicy: UInt8?

    public init(flags: DeviceState? = nil, advertPolicy: UInt8? = nil) {
      self.flags = flags
      self.advertPolicy = advertPolicy
    }

    /// Applies a HELLO reply or STATE push; other frames leave it unchanged.
    /// A HELLO reply without byte [8] keeps the known policy.
    public mutating func apply(_ frame: Frame) {
      switch frame {
      case let .helloReply(reply):
        flags = reply.state
        if let policy = reply.advertPolicy { advertPolicy = policy }
      case let .state(state, policy):
        flags = state
        advertPolicy = policy
      default:
        break
      }
    }
  }

  /// Delivery state carried by SENT_DM and SENT_STATUS.
  public enum SentStatus: UInt8, Sendable {
    case sent = 0
    case delivered = 1
    case retrying = 2
    case failed = 3
  }

  /// 0xE1 / 0x20 SENT_DM: a direct message composed on the device.
  public struct SentContactMessage: Sendable, Equatable {
    public let status: SentStatus
    public let attempt: UInt8
    public let recipientPrefix: Data
    public let pathLength: UInt8
    public let textType: UInt8
    public let timestamp: UInt32
    public let text: String
  }

  /// 0xE1 / 0x21 SENT_CHANNEL: a channel message composed on the device (body without "name: ").
  public struct SentChannelMessage: Sendable, Equatable {
    public let channelIndex: UInt8
    public let pathLength: UInt8
    public let textType: UInt8
    public let timestamp: UInt32
    public let text: String
  }

  /// 0xE1 / 0x22 SENT_STATUS: delivery update of a device-sent direct message.
  public struct SentMessageStatus: Sendable, Equatable {
    public let recipientPrefix: Data
    public let timestamp: UInt32
    public let status: SentStatus
    public let attempt: UInt8
    public let roundTripMs: UInt32
  }

  /// Every isra frame the firmware can send to a host.
  public enum Frame: Sendable, Equatable {
    case helloReply(HelloReply)
    case positionRequest
    /// 0xE1 / 0x11 STATE push.
    case state(DeviceState, advertPolicy: UInt8)
    case sentContactMessage(SentContactMessage)
    case sentChannelMessage(SentChannelMessage)
    case sentMessageStatus(SentMessageStatus)
    /// A 0xE1 frame with a sub-op this build does not know (newer revision).
    case unknown(subOp: UInt8)
  }

  /// Result of PHONE_POS.
  public enum PhonePositionOutcome: Sendable, Equatable {
    case accepted
    /// `ERR_CODE_BAD_STATE`: "Phone pos", GPS or GPS duty cycle off on the device.
    case badState
    /// `ERR_CODE_ILLEGAL_ARG`: 0,0, out of range, accuracy over 1000 m or age over 600 s.
    case illegalArgument
    case deviceError(UInt8)
  }

  // MARK: - Limits

  /// Firmware rejects worse accuracy (ILLEGAL_ARG).
  public static let maxAccuracyMeters: Double = 1000
  /// Firmware rejects older fixes (ILLEGAL_ARG).
  public static let maxAgeSeconds = 600

  // MARK: - Builders

  /// HELLO (0xE1 / 0x00) with the host caps.
  public static func hello(hostCaps: Caps) -> Data {
    var data = Data([code, SubOp.hello.rawValue])
    data.appendLE(hostCaps.rawValue)
    return data
  }

  /// PHONE_POS (0xE1 / 0x01). Returns nil for 0,0 or out-of-range coordinates.
  ///
  /// - Parameters:
  ///   - altitudeMeters: altitude above mean sea level, or nil when not valid.
  ///   - horizontalAccuracy: metres, or nil when unknown (sent as 0xFFFF).
  ///   - ageSeconds: age of the fix when sent.
  public static func phonePosition(
    latitude: Double,
    longitude: Double,
    altitudeMeters: Double?,
    horizontalAccuracy: Double?,
    ageSeconds: Int
  ) -> Data? {
    guard latitude.isFinite, longitude.isFinite,
          (-90.0...90.0).contains(latitude), (-180.0...180.0).contains(longitude),
          !(latitude == 0 && longitude == 0) else { return nil }
    var data = Data([code, SubOp.phonePosition.rawValue])
    data.appendLE(Int32((latitude * 1e6).rounded()))
    data.appendLE(Int32((longitude * 1e6).rounded()))
    let altitudeMM: Int32
    let flags: UInt8
    if let altitudeMeters, altitudeMeters.isFinite {
      let mm = (altitudeMeters * 1000).rounded()
      altitudeMM = Int32(max(Double(Int32.min), min(Double(Int32.max), mm)))
      flags = 0x01
    } else {
      altitudeMM = 0
      flags = 0x00
    }
    data.appendLE(altitudeMM)
    data.append(flags)
    let accuracy: UInt16 = if let horizontalAccuracy, horizontalAccuracy.isFinite, horizontalAccuracy >= 0 {
      UInt16(min(horizontalAccuracy.rounded(.up), 0xFFFE))
    } else {
      0xFFFF
    }
    data.appendLE(accuracy)
    data.appendLE(UInt16(clamping: max(0, ageSeconds)))
    return data
  }

  // MARK: - Timestamps

  /// Timestamp of a direct message sent by a host with SENT_MSGS in effect: `now`
  /// moved up to the next even second, and strictly after `last` (the previous one this
  /// host picked), so it never equals a device-sent DM's (always odd) nor an earlier
  /// host DM's. The ACK code hashes timestamp, attempt, text and sender key only.
  public static func evenHostTimestamp(now: UInt32, after last: UInt32?) -> UInt32 {
    var candidate = UInt64(now)
    if let last { candidate = max(candidate, UInt64(last) + 1) }
    if candidate % 2 != 0 { candidate += 1 }
    // Year 2106: stay in range rather than trap.
    return UInt32(min(candidate, UInt64(UInt32.max - 1)))
  }

  // MARK: - Parsing

  /// Whether a parse failure is a whole frame with a response code the parser does not know.
  ///
  /// `PacketParser` reports an unknown code with the full frame as data; a malformed frame
  /// of a known code carries only its payload, so the reason is checked too.
  public static func isUnknownCodeFrame(data: Data, reason: String) -> Bool {
    guard let first = data.first, ResponseCode(rawValue: first) == nil else { return false }
    return reason.hasPrefix("Unknown response code")
  }

  /// Unknown-code frame below 0x80: a reply to the command in flight (pushes are 0x80 and up).
  public static func isUnknownReplyFrame(data: Data, reason: String) -> Bool {
    guard isUnknownCodeFrame(data: data, reason: reason), let first = data.first else { return false }
    return first < 0x80
  }

  /// A frame the message drain takes as the reply to `CMD_SYNC_NEXT_MESSAGE` and skips:
  /// a device-sent message frame (0xE1 / 0x20-0x22; event subscribers read it), or any
  /// other unknown-code reply below 0x80. Never a push (0xE1 / 0x10, 0x80 and up).
  public static func isDrainSkipFrame(data: Data, reason: String) -> Bool {
    guard isUnknownCodeFrame(data: data, reason: reason) else { return false }
    if isSentMessageFrame(data) { return true }
    return isUnknownReplyFrame(data: data, reason: reason)
  }

  /// 0xE1 with sub-op 0x20, 0x21 or 0x22.
  public static func isSentMessageFrame(_ data: Data) -> Bool {
    guard data.count >= 2, data[data.startIndex] == code else { return false }
    switch SubOp(rawValue: data[data.startIndex + 1]) {
    case .sentContactMessage?, .sentChannelMessage?, .sentMessageStatus?: return true
    default: return false
    }
  }

  /// The isra frame carried by an event, if any.
  public static func frame(from event: MeshEvent) -> Frame? {
    guard case let .parseFailure(data, reason) = event,
          isUnknownCodeFrame(data: data, reason: reason) else { return nil }
    return parse(data)
  }

  /// Parses a raw frame (code byte first). Returns nil when it is not an isra frame or is too short.
  public static func parse(_ raw: Data) -> Frame? {
    let data = Data(raw)
    guard data.first == code, data.count >= 2 else { return nil }
    switch SubOp(rawValue: data[1]) {
    case .hello:
      guard data.count >= 8 else { return nil }
      return .helloReply(HelloReply(
        caps: Caps(rawValue: data.readUInt32LE(at: 2)),
        revision: data[6],
        state: DeviceState(rawValue: data[7]),
        advertPolicy: data.count >= 9 ? data[8] : nil
      ))

    case .positionRequest:
      return .positionRequest

    case .state:
      guard data.count >= 4 else { return nil }
      return .state(DeviceState(rawValue: data[2]), advertPolicy: data[3])

    case .sentContactMessage:
      // Draft frame 30 with [0] replaced by 0xE1, 0x20: every offset +1.
      guard data.count >= 17, let status = SentStatus(rawValue: data[2]) else { return nil }
      return .sentContactMessage(SentContactMessage(
        status: status,
        attempt: data[3],
        recipientPrefix: Data(data[5..<11]),
        pathLength: data[11],
        textType: data[12],
        timestamp: data.readUInt32LE(at: 13),
        text: String(decoding: data.dropFirst(17), as: UTF8.self)
      ))

    case .sentChannelMessage:
      guard data.count >= 12 else { return nil }
      return .sentChannelMessage(SentChannelMessage(
        channelIndex: data[5],
        pathLength: data[6],
        textType: data[7],
        timestamp: data.readUInt32LE(at: 8),
        text: String(decoding: data.dropFirst(12), as: UTF8.self)
      ))

    case .sentMessageStatus:
      guard data.count >= 18, let status = SentStatus(rawValue: data[12]) else { return nil }
      return .sentMessageStatus(SentMessageStatus(
        recipientPrefix: Data(data[2..<8]),
        timestamp: data.readUInt32LE(at: 8),
        status: status,
        attempt: data[13],
        roundTripMs: data.readUInt32LE(at: 14)
      ))

    case .phonePosition, nil:
      return .unknown(subOp: data[1])
    }
  }
}

private extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
