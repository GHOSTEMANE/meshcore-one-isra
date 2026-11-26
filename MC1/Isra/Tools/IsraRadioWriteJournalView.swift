import SwiftUI

/// "Registo de escritas no rádio": every write the app sent to the local radio, newest first.
struct IsraRadioWriteJournalView: View {
  @Environment(\.appTheme) private var theme
  @State private var model = IsraRadioWriteJournalModel.shared
  @State private var confirmingClear = false
  @State private var showAutomaticOnly = false

  private var shown: [IsraRadioWriteEntry] {
    let list = model.entries.reversed()
    return showAutomaticOnly ? list.filter { $0.trigger != nil } : Array(list)
  }

  var body: some View {
    List {
      Section {
        Toggle(IsraL10n.tr("Isra.Tools.Journal.automaticOnly"), isOn: $showAutomaticOnly)
      } footer: {
        Text(IsraL10n.tr("Isra.Tools.Journal.footer", IsraRadioWriteJournal.capacity))
      }
      .themedRowBackground(theme)

      if shown.isEmpty {
        Section {
          Text(IsraL10n.tr("Isra.Tools.Journal.empty"))
            .foregroundStyle(.secondary)
        }
        .themedRowBackground(theme)
      } else {
        Section {
          ForEach(shown) { entry in
            IsraRadioWriteRow(entry: entry)
          }
        }
        .themedRowBackground(theme)
      }
    }
    .themedCanvas(theme)
    .navigationTitle(IsraL10n.tr("Isra.Tools.Journal.title"))
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        ShareLink(item: model.exportText()) {
          Label(IsraL10n.tr("Isra.Tools.Journal.export"), systemImage: "square.and.arrow.up")
        }
        .disabled(model.entries.isEmpty)
        Button(role: .destructive) {
          confirmingClear = true
        } label: {
          Label(IsraL10n.tr("Isra.Tools.Journal.clear"), systemImage: "trash")
        }
        .disabled(model.entries.isEmpty)
      }
    }
    .confirmationDialog(
      IsraL10n.tr("Isra.Tools.Journal.clearConfirm"),
      isPresented: $confirmingClear,
      titleVisibility: .visible
    ) {
      Button(IsraL10n.tr("Isra.Tools.Journal.clear"), role: .destructive) { model.clear() }
    }
    .onAppear { model.attach() }
  }
}

private struct IsraRadioWriteRow: View {
  let entry: IsraRadioWriteEntry

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline) {
        Text(entry.what)
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(entry.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().second()))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      if let change = entry.change {
        Text(change)
          .font(.footnote.monospacedDigit())
      }
      HStack(spacing: 6) {
        Label(
          IsraRadioWriteJournal.triggerLabel(entry.trigger),
          systemImage: entry.trigger == nil ? "hand.tap" : "gearshape.2"
        )
        .foregroundStyle(entry.trigger == nil ? Color.secondary : Color.orange)
        Text("·").foregroundStyle(.secondary)
        Text(IsraRadioWriteJournal.resultLabel(entry.result) + (entry.detail.map { " (\($0))" } ?? ""))
          .foregroundStyle(resultColor)
      }
      .font(.caption)
    }
    .accessibilityElement(children: .combine)
  }

  private var resultColor: Color {
    switch entry.result {
    case .ok: .green
    case .error, .notSent: .red
    case .pending, .unknown: .secondary
    }
  }
}
