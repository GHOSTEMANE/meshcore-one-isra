import MC1Services
import SwiftUI

/// isra: what one contact may ask from this radio's telemetry (contact flag bits
/// 0x0E). Writing changes those three bits only; the favourite bit, remote CLI and
/// any other bit stay as the radio has them.
enum IsraTelemetryAccessText {
  static func label(_ access: IsraTelemetryAccess) -> String {
    switch access {
    case .nothing: IsraL10n.tr("Isra.UI.Access.nothing")
    case .status: IsraL10n.tr("Isra.UI.Access.status")
    case .statusAndLocation: IsraL10n.tr("Isra.UI.Access.statusLocation")
    case .statusAndSensors: IsraL10n.tr("Isra.UI.Access.statusSensors")
    case .all: IsraL10n.tr("Isra.UI.Access.all")
    }
  }

  static func label(flags: UInt8) -> String {
    IsraTelemetryAccess(flags: flags).map(label) ??
      IsraL10n.tr("Isra.UI.Access.other", Int(flags & IsraTelemetryAccess.mask))
  }
}

/// Picker rows for one contact. `bits` is the contact's current 0x0E value.
private struct IsraTelemetryAccessPicker: View {
  let title: String
  let bits: UInt8
  let isDisabled: Bool
  let onSelect: (UInt8) -> Void

  var body: some View {
    Picker(title, selection: Binding(get: { bits }, set: { if $0 != bits { onSelect($0) } })) {
      ForEach(IsraTelemetryAccess.allCases, id: \.rawValue) { access in
        Text(IsraTelemetryAccessText.label(access)).tag(access.rawValue)
      }
      if IsraTelemetryAccess(flags: bits) == nil {
        Text(IsraTelemetryAccessText.label(flags: bits)).tag(bits)
      }
    }
    .disabled(isDisabled)
  }
}

/// Settings › Telemetry › Authorized contacts (replaces TrustedContactsPickerView,
/// which granted or cleared all three bits together).
struct IsraTelemetryAccessListView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var contacts: [ContactDTO] = []
  @State private var searchText = ""
  @State private var showFavoritesOnly = false
  @State private var showAuthorizedOnly = false
  @State private var savingID: UUID?
  @State private var errorMessage: String?

  private var filteredContacts: [ContactDTO] {
    contacts.filter { contact in
      (!showFavoritesOnly || contact.isFavorite)
        && (!showAuthorizedOnly || contact.flags & IsraTelemetryAccess.mask != 0)
        && (searchText.isEmpty || contact.displayName.localizedStandardContains(searchText))
    }
  }

  var body: some View {
    List {
      Section {
        Toggle(L10n.Settings.TrustedContacts.favoritesOnly, isOn: $showFavoritesOnly)
        Toggle(IsraL10n.tr("Isra.UI.Access.authorizedOnly"), isOn: $showAuthorizedOnly)
      } footer: {
        Text(IsraL10n.tr("Isra.UI.Access.footer"))
      }
      .themedRowBackground(theme)

      Section {
        if contacts.isEmpty {
          ContentUnavailableView(
            L10n.Settings.TrustedContacts.noContacts,
            systemImage: "person.2.slash",
            description: Text(L10n.Settings.TrustedContacts.noContactsDescription)
          )
        } else if filteredContacts.isEmpty {
          ContentUnavailableView(
            L10n.Settings.TrustedContacts.noResults,
            systemImage: "magnifyingglass",
            description: Text(L10n.Settings.TrustedContacts.noResultsDescription(searchText))
          )
        } else {
          ForEach(filteredContacts) { contact in
            HStack {
              IsraTelemetryAccessPicker(
                title: contact.displayName,
                bits: contact.flags & IsraTelemetryAccess.mask,
                isDisabled: savingID != nil || appState.connectionState != .ready,
                onSelect: { save(contact, bits: $0) }
              )
              if savingID == contact.id {
                ProgressView().controlSize(.small)
              }
            }
          }
        }
      }
      .themedRowBackground(theme)
    }
    .themedCanvas(theme)
    .searchable(text: $searchText, prompt: L10n.Settings.TrustedContacts.searchPrompt)
    .navigationTitle(IsraL10n.tr("Isra.UI.Access.title"))
    .navigationBarTitleDisplayMode(.inline)
    .errorAlert($errorMessage)
    .task { await load() }
  }

  private func load() async {
    guard let radioID = appState.connectedDevice?.radioID,
          let contactService = appState.services?.contactService else { return }
    contacts = (try? await contactService.getContacts(radioID: radioID).filter { $0.type == .chat }) ?? []
  }

  private func save(_ contact: ContactDTO, bits: UInt8) {
    guard savingID == nil, let contactService = appState.services?.contactService else { return }
    savingID = contact.id
    Task {
      do {
        try await contactService.setTelemetryAccessBits(contact.id, bits: bits)
      } catch {
        errorMessage = error.userFacingMessage
      }
      await load()
      savingID = nil
    }
  }
}

/// Contact detail hook: the same choice for one contact.
struct IsraContactTelemetryAccessSection: View {
  @Environment(\.appState) private var appState
  let contact: ContactDTO
  @State private var flags: UInt8?
  @State private var isSaving = false
  @State private var errorMessage: String?

  var body: some View {
    Section {
      HStack {
        IsraTelemetryAccessPicker(
          title: IsraL10n.tr("Isra.UI.Access.rowLabel"),
          bits: (flags ?? contact.flags) & IsraTelemetryAccess.mask,
          isDisabled: isSaving || appState.connectionState != .ready,
          onSelect: save
        )
        if isSaving {
          ProgressView().controlSize(.small)
        }
      }
    } header: {
      Text(IsraL10n.tr("Isra.UI.Access.detailHeader"))
    } footer: {
      Text(IsraL10n.tr("Isra.UI.Access.detailFooter"))
    }
    .errorAlert($errorMessage)
    .task(id: contact.id) {
      flags = try? await appState.services?.contactService.getContactByID(contact.id)?.flags
    }
  }

  private func save(_ bits: UInt8) {
    guard !isSaving, let contactService = appState.services?.contactService else { return }
    isSaving = true
    Task {
      do {
        flags = try await contactService.setTelemetryAccessBits(contact.id, bits: bits)
      } catch {
        errorMessage = error.userFacingMessage
      }
      isSaving = false
    }
  }
}
