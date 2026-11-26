import Foundation

/// isra: CLI lines the app refuses before they reach any radio.
///
/// - The paired radio (MeshCore Solo) must never be rebooted by software: after a
///   soft reboot it can hang at boot until the power switch is off for 15 s.
///   A remote node's `reboot` (a repeater over the mesh) stays allowed.
/// - No OTA / DFU firmware update, on the paired radio or on a remote node:
///   firmware goes in by USB only.
public enum IsraCLIGuard {
  public enum Refusal: Equatable, Sendable {
    case localReboot
    case ota
  }

  /// Words that reboot the local radio when sent from the local session.
  private static let localRebootWords: Set<String> = ["reboot", "restart", "clkreboot"]

  /// Why `line` must not be sent, or nil when it may go.
  /// - Parameter isLocal: true for the paired radio's session.
  public static func refusal(for line: String, isLocal: Bool) -> Refusal? {
    let words = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
    guard let first = words.first else { return nil }
    if words.contains(where: isOTAWord) { return .ota }
    if isLocal, localRebootWords.contains(first) { return .localReboot }
    return nil
  }

  /// Command names hidden from completion.
  public static func hidesCompletion(_ command: String, isLocal: Bool) -> Bool {
    let word = command.lowercased()
    if word == "start" || isOTAWord(word) { return true }
    return isLocal && localRebootWords.contains(word)
  }

  /// `ota`, `dfu` and words built on them (`ota.start`, `dfu_mode`), not names that
  /// merely begin with those letters (`otavio`).
  static func isOTAWord(_ word: String) -> Bool {
    let word = word.drop { !$0.isLetter && !$0.isNumber }
    for stem in ["ota", "dfu"] where word.hasPrefix(stem) {
      let rest = word.dropFirst(stem.count)
      if rest.isEmpty || !(rest.first?.isLetter ?? false) { return true }
    }
    return false
  }
}
