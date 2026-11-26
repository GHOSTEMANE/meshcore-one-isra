import Foundation
@testable import MC1Services
@testable import MeshCore
import Testing

@Suite("isra telemetry access bits")
struct IsraTelemetryAccessTests {
  @Test
  func `applying replaces only bits 0x0E`() {
    // favourite + remote CLI + all telemetry -> status only
    #expect(IsraTelemetryAccess.applying(0x02, to: 0x1F) == 0x13)
    // nothing set -> location + status, favourite kept
    #expect(IsraTelemetryAccess.applying(0x06, to: 0x01) == 0x07)
    // bits outside the mask in the request are ignored
    #expect(IsraTelemetryAccess.applying(0xFF, to: 0x00) == 0x0E)
    #expect(IsraTelemetryAccess.applying(0x00, to: 0xFF) == 0xF1)
  }

  @Test
  func `named choices map from flags`() {
    #expect(IsraTelemetryAccess(flags: 0x01) == .nothing)
    #expect(IsraTelemetryAccess(flags: 0x03) == .status)
    #expect(IsraTelemetryAccess(flags: 0x07) == .statusAndLocation)
    #expect(IsraTelemetryAccess(flags: 0x0B) == .statusAndSensors)
    #expect(IsraTelemetryAccess(flags: 0x1F) == .all)
    #expect(IsraTelemetryAccess(flags: 0x04) == nil)
  }

  @Test
  func `modes keep the low two bits`() {
    #expect(IsraTelemetryMode(raw: 2) == .everyone)
    #expect(IsraTelemetryMode(raw: 0x81) == .authorizedContacts)
    #expect(IsraTelemetryMode(raw: 3) == nil)
  }

  private func makeService(radioID: UUID) async throws -> (ContactService, PersistenceStore, MockMeshCoreSession) {
    let store = try await PersistenceStore.createTestDataStore(radioID: radioID)
    let session = MockMeshCoreSession()
    let service = ContactService(session: session, dataStore: store, syncCoordinator: nil, cleanupCoordinator: nil)
    return (service, store, session)
  }

  @Test
  func `service writes the bits and keeps favourite and remote CLI from the radio`() async throws {
    let radioID = UUID()
    let (service, store, session) = try await makeService(radioID: radioID)
    // Local copy says "nothing"; the radio has favourite + remote CLI + all telemetry.
    let local = ContactDTO.testContact(radioID: radioID, flags: ContactFlags.favorite.rawValue)
    try await store.saveContact(local)
    let radioFlags = ContactFlags.favorite.rawValue | ContactFlags.remoteCLIAllowed.rawValue
      | ContactFlags.telemetryAll.rawValue
    await session.seedRadioContact(
      ContactDTO.testContact(publicKey: local.publicKey, flags: radioFlags).toContactFrame().toMeshContact()
    )

    let result = try await service.setTelemetryAccessBits(local.id, bits: IsraTelemetryAccess.statusAndLocation.rawValue)

    #expect(result == 0x17)
    #expect(await session.changeContactFlagsCalls.last?.flags.rawValue == 0x17)
    let stored = try #require(await store.fetchContact(id: local.id))
    #expect(stored.flags == 0x17)
    #expect(stored.name == local.name)
  }

  @Test
  func `no radio write when the bits are already right`() async throws {
    let radioID = UUID()
    let (service, store, session) = try await makeService(radioID: radioID)
    let contact = ContactDTO.testContact(radioID: radioID, flags: 0x07)
    try await store.saveContact(contact)
    await session.seedRadioContact(contact.toContactFrame().toMeshContact())

    let result = try await service.setTelemetryAccessBits(contact.id, bits: 0x06)

    #expect(result == 0x07)
    #expect(await session.changeContactFlagsCalls.isEmpty)
  }
}
