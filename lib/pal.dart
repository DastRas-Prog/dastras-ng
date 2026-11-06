import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// dark | light | system (default: light)
final ValueNotifier<String> themeN = ValueNotifier<String>('light');

Future<void> saveTheme(String m) async {
  themeN.value = m;
  final p = await SharedPreferences.getInstance();
  await p.setString('theme', m);
}

/// Colour palette that follows the chosen theme.
class Pal {
  static bool get dark {
    final m = themeN.value;
    if (m == 'system') {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    return m != 'light';
  }

  static Color _c(Color d, Color l) => dark ? d : l;

  static Color get bg0 => _c(const Color(0xFF080D1F), const Color(0xFFF2F5FC));
  static Color get bg1 => _c(const Color(0xFF121B3D), const Color(0xFFDCE5F8));
  static Color get card => _c(const Color(0x14FFFFFF), const Color(0xCCFFFFFF));
  static Color get cardBorder => _c(const Color(0x22FFFFFF), const Color(0x1A1B2A5A));
  static Color get sheetTop => _c(const Color(0xE60F1736), const Color(0xF5FFFFFF));
  static Color get sheetBottom => _c(const Color(0xF20A1030), const Color(0xFAF4F7FE));
  static Color get dialog => _c(const Color(0xFF151D40), Colors.white);
  static Color get t1 => _c(Colors.white, const Color(0xFF0D1633));
  static Color get t2 => _c(const Color(0xB3FFFFFF), const Color(0xB30D1633));
  static Color get t3 => _c(const Color(0x8AFFFFFF), const Color(0x8A0D1633));
  static Color get t4 => _c(const Color(0x61FFFFFF), const Color(0x610D1633));
  static Color get accent => _c(const Color(0xFF5B8CFF), const Color(0xFF3563E9));
  static Color get cyan => _c(const Color(0xFF4DD6E8), const Color(0xFF0A93AE));
  static Color get green => _c(const Color(0xFF2EE59D), const Color(0xFF0FA968));
  static Color get orange => _c(const Color(0xFFFFB020), const Color(0xFFE08600));
  static Color get red => _c(const Color(0xFFFF6B6B), const Color(0xFFD93A3A));
  static Color get globe => _c(const Color.fromRGBO(120, 170, 255, 0.10), const Color.fromRGBO(40, 80, 180, 0.11));
  static Color get dot => _c(const Color.fromRGBO(140, 200, 255, 1), const Color.fromRGBO(40, 90, 190, 1));
  static Color get navBg => _c(const Color(0xCC121B3D), const Color(0xD9FFFFFF));
  static Color get shadow => _c(const Color(0x66000000), const Color(0x26284080));
}
