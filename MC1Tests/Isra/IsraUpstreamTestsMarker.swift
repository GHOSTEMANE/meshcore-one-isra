import Foundation

/// isra test fixture. Its presence in the loaded test bundle tells the app
/// (`IsraTestHost.upstreamTestsLoaded`) that upstream's tests are running:
/// - `IsraConfigImportGuard.shared` starts imports with every opt-in on, because
///   upstream's config-import tests import a private key and telemetry modes through
///   the view model and expect them written;
/// - the host-caps provider returns no caps, so no HELLO goes to the mock radios
///   (they never answer it, and each unanswered HELLO costs 3 s inside APP_START,
///   which breaks upstream's timing). The hooks stay installed, so the isra drain and
///   config-import paths still run.
/// The app has no such class, so none of this can happen outside the test bundle.
@objc(IsraUpstreamTestsMarker)
final class IsraUpstreamTestsMarker: NSObject {}
