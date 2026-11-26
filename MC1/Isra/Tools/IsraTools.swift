import SwiftUI

/// Entry point of the isra tools (radio-writes journal, airtime meter).
@MainActor
enum IsraTools {
  /// Called once the app's data is available, before the first connection.
  static func start(appState: AppState) {
    IsraRadioWriteJournal.shared.install()
    IsraRadioWriteJournalModel.shared.attach()
    IsraAirtimeMeter.shared.start(appState: appState)
  }
}

/// Settings > Advanced: the isra tools that are not tied to one setting.
struct IsraToolsSettingsSection: View {
  @Environment(\.appTheme) private var theme
  @State private var showingJournal = false
  @State private var model = IsraRadioWriteJournalModel.shared

  var body: some View {
    Section {
      Button {
        showingJournal = true
      } label: {
        HStack {
          TintedLabel(IsraL10n.tr("Isra.Tools.Journal.title"), systemImage: "list.bullet.rectangle.portrait")
          Spacer()
          Text(String(model.entries.count))
            .foregroundStyle(.secondary)
        }
      }
    } header: {
      Text(IsraL10n.tr("Isra.Tools.header"))
    } footer: {
      Text(IsraL10n.tr("Isra.Tools.Journal.rowFooter"))
    }
    .themedRowBackground(theme)
    .sheet(isPresented: $showingJournal) {
      NavigationStack {
        IsraRadioWriteJournalView()
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button(L10n.Localizable.Common.done) { showingJournal = false }
            }
          }
      }
    }
  }
}
