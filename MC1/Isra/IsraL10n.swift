import Foundation

/// Strings of the isra fork, kept in their own table (Isra.strings, en + pt) so the
/// generated L10n.swift and upstream's .strings files are never edited.
enum IsraL10n {
  static func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, tableName: "Isra", bundle: .main, comment: "")
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
  }
}
