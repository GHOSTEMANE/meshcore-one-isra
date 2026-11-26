import SwiftUI

/// Sub-page wrapping LocationSettingsSection for the settings navigation
struct LocationSettingsView: View {
  @Environment(\.appState) private var appState
  @Environment(\.appTheme) private var theme
  @State private var showingLocationPicker = false

  var body: some View {
    List {
      #if ISRA // isra: never switches the radio GPS off, advert policy read-only; phone position for telemetry
        IsraLocationSettingsSection(showingLocationPicker: $showingLocationPicker)
        IsraPhonePosSection() // isra: MC1/Isra
      #else
        LocationSettingsSection(showingLocationPicker: $showingLocationPicker)
      #endif
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.Location.header)
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showingLocationPicker) {
      #if ISRA // isra: a manual position writes only the coordinates
        LocationPickerView.israForLocalDevice(appState: appState)
      #else
        LocationPickerView.forLocalDevice(appState: appState)
      #endif
    }
  }
}
