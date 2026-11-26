import Foundation

/// isra companion protocol extensions, revision 1 (see `isra/PROTOCOL.md`).
///
/// One private opcode, 0xE1, with a sub-op byte, plus the device-sent message
/// frames 30 / 31 / 32. Stock firmware answers 0xE1 with
/// `ERR_CODE_UNSUPPORTED_CMD` and never sends any of these frames.
public enum IsraProtocol {
  /// Opcode of every isra command, reply and push.
  public static let code: UInt8 = 0xE1
  /// Protocol revision this build understands.
  public static let revision: UInt8 = 1

  /// Sub-op byte after ``code``.
  public enum SubOp: UInt8, Sendable {
    case hello = 0x00
    case phonePosition = 0x01
    case positionRequest = 0x10
  }

  /// Frame codes of device-sent messages (section 3), delivered by `CMD_SYNC_NEXT_MESSAGE`.
  public static let sentContactMessageCode: UInt8 = 30
  public static let sentChannelMessageCode: UInt8 = 31
  public static let sentMessageStatusCode: UInt8 = 32

  /// Capability bits shared by host and firmware (HELLO).
  public struct Caps: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// Frames 30 / 31 / 32 (messages sent from the device).
    public static let sentMessages = Caps(rawValue: 1 << 0)
    /// Position requests answered with PHONE_POS.
    public static let phonePosition = Caps(rawValue: 1 << 1)
  }

  /// Device state flags in the HELLO reply.
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

    public init(caps: Caps, revision: UInt8, state: DeviceState) {
      self.caps = caps
      self.revision = revision
      self.state = state
    }
  }

  /// Delivery state carried by frames 30 and 32.
  public enum SentStatus: UInt8, Sendable {
    case sent = 0
    case delivered = 1
    case retrying = 2
    case failed = 3
  }

  /// Frame 30: a direct message composed on the device.
  public struct SentContactMessage: Sendable, Equatable {
    public let status: SentStatus
    public let attempt: UInt8
    public let recipientPrefix: Data
    public let pathLength: UInt8
    public let textType: UInt8
    public let timestamp: UInt32
    public let text: String
  }

  /// Frame 31: a channel message composed on the device (body without "name: ").
  public struct SentChannelMessage: Sendable, Equatable {
    public let channelIndex: UInt8
    public let pathLength: UInt8
    public let textType: UInt8
    public let timestamp: UInt32
    public let text: String
  }

  /// Frame 32: delivery update of a device-sent direct message.
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

  /// The isra frame carried by an event, if any.
  public static func frame(from event: MeshEvent) -> Frame? {
    guard case let .parseFailure(data, reason) = event,
          isUnknownCodeFrame(data: data, reason: reason) else { return nil }
    return parse(data)
  }

  /// Parses a raw frame (code byte first). Returns nil when it is not an isra frame or is too short.
  public static func parse(_ raw: Data) -> Frame? {
    let data = Data(raw)
    guard let first = data.first else { return nil }
    switch first {
    case code:
      guard data.count >= 2 else { return nil }
      switch SubOp(rawValue: data[1]) {
      case .hello:
        guard data.count >= 8 else { return nil }
        return .helloReply(HelloReply(
          caps: Caps(rawValue: data.readUInt32LE(at: 2)),
          revision: data[6],
          state: DeviceState(rawValue: data[7])
        ))
      case .positionRequest:
        return .positionRequest
      case .phonePosition, nil:
        return .unknown(subOp: data[1])
      }

    case sentContactMessageCode:
      guard data.count >= 16, let status = SentStatus(rawValue: data[1]) else { return nil }
      return .sentContactMessage(SentContactMessage(
        status: status,
        attempt: data[2],
        recipientPrefix: Data(data[4..<10]),
        pathLength: data[10],
        textType: data[11],
        timestamp: data.readUInt32LE(at: 12),
        text: String(decoding: data.dropFirst(16), as: UTF8.self)
      ))

    case sentChannelMessageCode:
      guard data.count >= 11 else { return nil }
      return .sentChannelMessage(SentChannelMessage(
        channelIndex: data[4],
        pathLength: data[5],
        textType: data[6],
        timestamp: data.readUInt32LE(at: 7),
        text: String(decoding: data.dropFirst(11), as: UTF8.self)
      ))

    case sentMessageStatusCode:
      guard data.count >= 17, let status = SentStatus(rawValue: data[11]) else { return nil }
      return .sentMessageStatus(SentMessageStatus(
        recipientPrefix: Data(data[1..<7]),
        timestamp: data.readUInt32LE(at: 7),
        status: status,
        attempt: data[12],
        roundTripMs: data.readUInt32LE(at: 13)
      ))

    default:
      return nil
    }
  }
}

private extension Data {
  mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}
