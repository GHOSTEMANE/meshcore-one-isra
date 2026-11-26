import Foundation
import MeshCore

// isra: telemetry permissions handled per category, never all three at once.
//
// Radio side (SELF_INFO / CMD_SET_OTHER_PARAMS): one mode per category,
// 0 = nobody, 1 = contacts with that category's permission bit, 2 = everyone.
// Contact side (contact flags): bit 1 = base (0x02), bit 2 = location (0x04),
// bit 3 = environment (0x08). Bit 0 is the favourite, bit 4 remote CLI; every
// bit outside 0x0E belongs to someone else and is always kept.

/// One telemetry category's radio-wide mode.
public enum IsraTelemetryMode: UInt8, CaseIterable, Sendable {
  case nobody = 0
  case authorizedContacts = 1
  case everyone = 2

  /// Maps a raw mode byte (low two bits, as the firmware keeps it). 3 is not a
  /// mode the firmware defines; it is shown as is and never written by the app.
  public init?(raw: UInt8) {
    self.init(rawValue: raw & 0b11)
  }
}

/// What one contact may ask: the telemetry bits 0x0E of its flags.
public enum IsraTelemetryAccess: UInt8, CaseIterable, Sendable {
  case nothing = 0x00
  case status = 0x02
  case statusAndLocation = 0x06
  case statusAndSensors = 0x0A
  case all = 0x0E

  /// The telemetry bits of a contact's flags.
  public static let mask: UInt8 = ContactFlags.telemetryAll.rawValue

  /// The access a contact's flags give, or nil for a combination without a
  /// named choice (e.g. location without status).
  public init?(flags: UInt8) {
    self.init(rawValue: flags & Self.mask)
  }

  /// `flags` with the telemetry bits replaced by `bits`; every other bit is kept.
  public static func applying(_ bits: UInt8, to flags: UInt8) -> UInt8 {
    (flags & ~mask) | (bits & mask)
  }
}

public extension ContactService {
  /// isra: writes exactly `bits` (masked to 0x0E) into a contact's telemetry
  /// permission bits on the radio. Starts from the radio's live record, so the
  /// favourite bit, remote CLI and any other bit stay as the radio has them.
  /// Then mirrors the radio's resulting flags into the local store, changing
  /// nothing else there.
  ///
  /// - Returns: The contact's flags as the radio holds them after the write.
  @discardableResult
  func setTelemetryAccessBits(_ contactID: UUID, bits: UInt8) async throws -> UInt8 {
    guard let existing = try await dataStore.fetchContact(id: contactID) else {
      throw ContactServiceError.contactNotFound
    }
    let radio: MeshContact
    do {
      guard let fetched = try await session.getContact(publicKey: existing.publicKey) else {
        throw ContactServiceError.contactNotFound
      }
      radio = fetched
    } catch let error as MeshCoreError {
      throw ContactServiceError.sessionError(error)
    }

    let current = radio.flags.rawValue
    let wanted = IsraTelemetryAccess.applying(bits, to: current)
    var final = current
    if wanted != current {
      do {
        try await session.changeContactFlags(radio, flags: ContactFlags(rawValue: wanted))
        final = try await session.getContact(publicKey: existing.publicKey)?.flags.rawValue ?? wanted
      } catch let error as MeshCoreError {
        throw ContactServiceError.sessionError(error)
      }
    }

    // Local copy: same record, only the flags (the store keeps its own favourite bit).
    if existing.flags != final {
      let frame = ContactFrame(
        publicKey: existing.publicKey,
        type: existing.type,
        typeRawValue: existing.typeRawValue,
        flags: final,
        outPathLength: existing.outPathLength,
        outPath: existing.outPath,
        name: existing.name,
        lastAdvertTimestamp: existing.lastAdvertTimestamp,
        latitude: existing.latitude,
        longitude: existing.longitude,
        lastModified: existing.lastModified
      )
      _ = try await dataStore.saveContact(radioID: existing.radioID, from: frame)
    }
    return final
  }
}
