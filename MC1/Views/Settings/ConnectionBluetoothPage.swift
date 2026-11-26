import SwiftUI

/// PIN rows for the phone's Bluetooth link.
struct ConnectionBluetoothPage: View {
  @Environment(\.appTheme) private var theme

  var body: some View {
    List {
      #if ISRA // isra: PIN random (0) or custom, never 123456, no reboot
        IsraBluetoothSection()
      #else
        BluetoothSection()
      #endif
    }
    .themedCanvas(theme)
    .navigationTitle(L10n.Settings.Bluetooth.header)
    .navigationBarTitleDisplayMode(.inline)
  }
}
