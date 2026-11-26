import Foundation
import MeshCore

extension ServiceContainer {
  /// Starts the device-sent message listener before the first message drain.
  /// Only when the app installed the isra hooks (ISRA builds); otherwise a no-op.
  func israStartSentMessages(radioID: UUID) async {
    guard IsraHooks.isInstalled, israSentMessages == nil else { return }
    let service = IsraSentMessageService(
      session: session,
      dataStore: dataStore,
      messageService: messageService,
      syncCoordinator: syncCoordinator,
      rxLogService: rxLogService,
      heardRepeatsService: heardRepeatsService,
      receiveLifetime: receiveLifetime,
      radioID: radioID
    )
    israSentMessages = service
    await service.start()
  }

  func israStopSentMessages() async {
    let service = israSentMessages
    israSentMessages = nil
    await service?.stop()
  }
}
