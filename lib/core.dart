import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';

import 'win_core.dart';

class AppInfo {
  final String pkg, name;
  final Uint8List icon;
  AppInfo(this.pkg, this.name, this.icon);
}

class Traffic {
  final int down, up, totDown, totUp; // bytes/s, bytes/s, bytes, bytes
  const Traffic(this.down, this.up, this.totDown, this.totUp);
  static const zero = Traffic(0, 0, 0, 0);
}

/// Bridge to the native side: Android (libXray + VpnService) or Windows (xray.exe + system proxy).
class Core {
  static const _ch = MethodChannel('dastras/core');
  static bool get _win => Platform.isWindows;

  /// Calls libXray's single entry point (apiVersion 3).
  static Future<Map<String, dynamic>> invoke(String method, Map<String, dynamic> payload) async {
    if (_win) return WinCore.invoke(method, payload);
    final req = jsonEncode({'apiVersion': 3, 'method': method, 'payload': payload});
    final res = await _ch.invokeMethod<String>('invoke', req);
    try {
      return Map<String, dynamic>.from(jsonDecode(res ?? '{}') as Map);
    } catch (_) {
      return {'success': false, 'error': res ?? 'empty response'};
    }
  }

  /// mode: all | include | exclude (Android only)
  static Future<String> start(
    String config, {
    required String mode,
    required List<String> apps,
    required List<String> dns,
    required bool ipv6,
    required String lang,
    int mtu = 1500,
    List<String> announceUrls = const [],
  }) async {
    if (_win) return WinCore.start(config);
    return (await _ch.invokeMethod<String>('start', {
          'config': config,
          'mode': mode,
          'apps': apps,
          'dns': dns,
          'ipv6': ipv6,
          'mtu': mtu,
          'lang': lang,
          'ann': announceUrls,
        })) ??
        'error';
  }

  static Future<void> stop() async {
    if (_win) return WinCore.stop();
    await _ch.invokeMethod('stop');
  }

  static Future<String> status() async {
    if (_win) return WinCore.state;
    return (await _ch.invokeMethod<String>('status')) ?? 'stopped';
  }

  static Future<Traffic> stats() async {
    if (_win) return Traffic(WinCore.down, WinCore.up, WinCore.totDown, WinCore.totUp);
    final s = await _ch.invokeMethod<String>('stats');
    final p = (s ?? '').split(',').map((e) => int.tryParse(e) ?? 0).toList();
    if (p.length < 4) return Traffic.zero;
    return Traffic(p[0], p[1], p[2], p[3]);
  }

  /// Fetches the announcements JSON. Returns the raw JSON array or null on failure.
  static Future<String?> announceCheck(List<String> urls, {bool notify = false}) async {
    if (_win) return WinCore.announce(urls);
    final r = await _ch.invokeMethod<String>('announce', {'urls': urls, 'notify': notify});
    return (r == null || r.isEmpty) ? null : r;
  }

  static Future<String> abi() async {
    if (_win) return 'windows';
    return (await _ch.invokeMethod<String>('abi')) ?? 'arm64-v8a';
  }

  static Future<String> cacheDir() async {
    if (_win) return Directory.systemTemp.path;
    return (await _ch.invokeMethod<String>('cacheDir')) ?? '';
  }

  /// Android: opens the system installer. Windows: unpacks the update and restarts the app.
  static Future<String> installApk(String path) async {
    if (_win) return WinCore.applyUpdate(path);
    return (await _ch.invokeMethod<String>('installApk', path)) ?? 'error';
  }

  static Future<void> share(String text) async {
    if (_win) {
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }
    await _ch.invokeMethod('share', text);
  }

  static Future<void> notify(String title, String body, {int id = 3000}) async {
    if (_win) return;
    await _ch.invokeMethod('notify', {'title': title, 'body': body, 'id': id});
  }

  static Future<void> vpnSettings() async {
    if (_win) return;
    await _ch.invokeMethod('vpnSettings');
  }

  static Future<List<AppInfo>> apps() async {
    if (_win) return [];
    final s = await _ch.invokeMethod<String>('apps');
    final list = jsonDecode(s ?? '[]') as List;
    final out = <AppInfo>[];
    for (final e in list) {
      final m = Map<String, dynamic>.from(e as Map);
      out.add(AppInfo(m['pkg'] as String, m['name'] as String, base64Decode(m['icon'] as String)));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}
