import 'dart:io' show Platform;

/// Windows and macOS run Xray as a local proxy and set the system proxy.
bool get isDesktop => Platform.isWindows || Platform.isMacOS;
