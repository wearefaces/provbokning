/// Configuration for the mobile client.
///
/// The base URL points at the production server by default. Override at build
/// time via:
///
///     flutter run --dart-define=API_BASE_URL=https://staging.example.com
class AppConfig {
  /// Empty default = relative URLs (works when the app is served from the
  /// same origin as the API, e.g. https://<host>/m/). Override for cross-origin
  /// dev builds with --dart-define=API_BASE_URL=http://localhost:5000
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: '',
  );
}
