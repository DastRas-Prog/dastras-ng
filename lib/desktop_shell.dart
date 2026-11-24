/// Placeholder (Android, and desktop builds where the tray plugins are not available).
class DesktopShell {
  static Future<void> init({required bool startHidden}) async {}
  static void handlers({Future<void> Function()? onToggle, Future<void> Function()? onExit}) {}
  static Future<void> setConnected(bool v) async {}
  static Future<void> quit() async {}
  static Future<void> setTip(String text) async {}
}
