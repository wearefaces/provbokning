/// Configuration for the mobile client.
///
/// The base URL points at the production server by default. Override at build
/// time via:
///
///     flutter run --dart-define=API_BASE_URL=https://staging.example.com
class AppConfig {
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://provbok.8-229-124-88.nip.io',
  );
}
