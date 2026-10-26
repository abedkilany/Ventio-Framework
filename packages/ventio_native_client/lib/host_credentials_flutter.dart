/// Platform-backed Host credential storage for Flutter applications.
///
/// Kept separate from the pure Dart client API so command queue recovery tools
/// can use the base package without loading Flutter plugins.
library;

export 'src/platform_host_credentials.dart';
