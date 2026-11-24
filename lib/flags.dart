import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

/// All country flags live in one asset file: [4 bytes header length][JSON index][PNG data].
class FlagPack {
  static Map<String, List<int>> _idx = {};
  static Uint8List? _data;

  static Future<void> load() async {
    if (_data != null) return;
    try {
      final b = await rootBundle.load('assets/flags.bin');
      final bytes = b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes);
      final hl = ByteData.sublistView(bytes, 0, 4).getUint32(0);
      final head = jsonDecode(utf8.decode(bytes.sublist(4, 4 + hl))) as Map;
      _idx = head.map((k, v) => MapEntry(k.toString(), List<int>.from(v as List)));
      _data = Uint8List.sublistView(bytes, 4 + hl);
    } catch (_) {
      _data = Uint8List(0);
    }
  }

  static Uint8List? get(String code) {
    final e = _idx[code];
    final d = _data;
    if (e == null || d == null) return null;
    return Uint8List.sublistView(d, e[0], e[0] + e[1]);
  }
}
