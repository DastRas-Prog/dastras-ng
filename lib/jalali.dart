import 'lang.dart';

/// Gregorian -> Jalali (Persian) calendar.
List<int> toJalali(int gy, int gm, int gd) {
  const gdm = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  final gy2 = gm > 2 ? gy + 1 : gy;
  var days = 355666 + 365 * gy + (gy2 + 3) ~/ 4 - (gy2 + 99) ~/ 100 + (gy2 + 399) ~/ 400 + gd + gdm[gm - 1];
  var jy = -1595 + 33 * (days ~/ 12053);
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  int jm, jd;
  if (days < 186) {
    jm = 1 + days ~/ 31;
    jd = 1 + days % 31;
  } else {
    jm = 7 + (days - 186) ~/ 30;
    jd = 1 + (days - 186) % 30;
  }
  return [jy, jm, jd];
}

String faDigits(String s) {
  const f = '۰۱۲۳۴۵۶۷۸۹';
  return s.replaceAllMapped(RegExp(r'\d'), (m) => f[int.parse(m[0]!)]);
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Persian UI: Jalali date with Persian digits (1405/09/14). English UI: 2026-12-05.
String formatDate(DateTime d) {
  if (!isFa) return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  final j = toJalali(d.year, d.month, d.day);
  return faDigits('${j[0]}/${_two(j[1])}/${_two(j[2])}');
}

String formatDateTime(DateTime d) {
  final t = '${_two(d.hour)}:${_two(d.minute)}';
  return isFa ? faDigits('${formatDate(d)}  $t') : '${formatDate(d)} $t';
}
