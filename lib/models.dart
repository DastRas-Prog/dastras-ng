import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SubInfo {
  final int used, total, expire; // bytes, bytes, unix seconds
  const SubInfo(this.used, this.total, this.expire);

  Map<String, dynamic> toJson() => {'u': used, 't': total, 'e': expire};

  factory SubInfo.fromJson(Map<String, dynamic> j) => SubInfo(
        (j['u'] as int?) ?? 0,
        (j['t'] as int?) ?? 0,
        (j['e'] as int?) ?? 0,
      );
}

/// Result of a TCP connect test (several samples).
class TcpStat {
  final int ok, total, min, max;
  final double avg;
  const TcpStat(this.ok, this.total, this.min, this.max, this.avg);

  /// Lower is better: latency + penalty for lost samples + jitter.
  double get score => ok == 0 ? 1e9 : avg + (total - ok) * 800 + (max - min) * 1.5;
}

class Node {
  static String pingMode = 'tcp'; // tcp | real

  final Map<String, dynamic> ob;
  final String src; // 'sub' or 'manual'
  int? tcp, real;
  TcpStat? stat;
  bool tested = false;
  Node(this.ob, this.src);

  int? get delay => pingMode == 'real' ? real : tcp;

  String get name => (ob['tag'] ?? ob['protocol'] ?? 'node').toString();
  String get key => '$name|$address';
  String? link; // the original share link (only for configs added by hand)

  /// 1 or 2 from the name's trailing number ("UK 1", "IT 2"); falls back to the protocol (trojan = 1, vless = 2).
  String get group {
    final m = RegExp(r'(\d+)\s*$').firstMatch(name.trim());
    if (m != null) {
      final n = int.parse(m.group(1)!);
      if (n == 1 || n == 2) return '$n';
    }
    final p = (ob['protocol'] ?? '').toString();
    if (p == 'trojan') return '1';
    if (p == 'vless') return '2';
    return '';
  }

  /// Panels add fake "servers" that only show the account (user name, days left...). Never auto-select them.
  bool get isInfo {
    if (RegExp(r'(user\s*:|days?\s*left|data\s*left|expire|volume|used\s*:)', caseSensitive: false).hasMatch(name)) return true;
    final h = endpoint?.$1 ?? '';
    return h == '127.0.0.1' || h == '0.0.0.0' || h == 'localhost';
  }
  String get protocol => (ob['protocol'] ?? '').toString().toUpperCase();

  Map<String, dynamic> get _stream =>
      ob['streamSettings'] is Map ? Map<String, dynamic>.from(ob['streamSettings'] as Map) : {};

  String get transport => (_stream['network'] ?? 'tcp').toString().toUpperCase();

  String get security {
    final s = (_stream['security'] ?? '').toString();
    return (s.isEmpty || s == 'none') ? '' : s.toUpperCase();
  }

  /// e.g. "VLESS / WS / TLS"
  String get subtitle {
    final parts = [protocol, transport, security].where((e) => e.isNotEmpty);
    return parts.join(' / ');
  }

  (String, int)? get endpoint {
    final s = ob['settings'];
    if (s is! Map) return null;
    Map? m;
    final v = s['vnext'];
    final sv = s['servers'];
    if (v is List && v.isNotEmpty && v[0] is Map) {
      m = v[0] as Map;
    } else if (sv is List && sv.isNotEmpty && sv[0] is Map) {
      m = sv[0] as Map;
    } else if (s['address'] != null) {
      m = s;
    }
    if (m == null) return null;
    final host = m['address']?.toString();
    final port = int.tryParse('${m['port']}');
    if (host == null || host.isEmpty || port == null) return null;
    return (host, port);
  }

  String get address {
    final e = endpoint;
    return e == null ? '' : '${e.$1}:${e.$2}';
  }

  /// Flag emoji from a leading country code ("CH 2") or an emoji in the name.
  String? get flag {
    final n = name;
    final m = RegExp('[\u{1F1E6}-\u{1F1FF}]{2}', unicode: true).firstMatch(n);
    if (m != null) return m.group(0);
    final c = RegExp(r'^\s*([A-Za-z]{2})(?![A-Za-z])').firstMatch(n);
    if (c != null) {
      final code = c.group(1)!.toUpperCase();
      return String.fromCharCodes(code.codeUnits.map((u) => 0x1F1E6 + u - 65));
    }
    return null;
  }

  Map<String, dynamic> toJson() => {'ob': ob, 'src': src, 'tcp': tcp, 'real': real, 't': tested, 'lnk': link};

  factory Node.fromJson(Map<String, dynamic> j) {
    final n = Node(Map<String, dynamic>.from(j['ob'] as Map), (j['src'] ?? 'manual').toString());
    n.tcp = j['tcp'] is int ? j['tcp'] as int : null;
    n.real = j['real'] is int ? j['real'] as int : (j['d'] is int ? j['d'] as int : null);
    n.tested = j['t'] == true;
    n.link = j['lnk'] is String ? j['lnk'] as String : null;
    return n;
  }
}

class Store {
  static const _sec = FlutterSecureStorage();
  late SharedPreferences _p;

  List<Node> nodes = [];
  List<String> subs = [];
  int selected = 0;
  SubInfo? info;
  int updatedMs = 0;
  String lastClip = '';
  String subTitle = '';

  // per-app proxy
  String perAppMode = 'all'; // all | include | exclude
  Set<String> perAppList = {};

  // settings
  bool bypassIran = true;
  bool autoSelect = true;
  bool autoUpdate = true;
  int updateEveryMin = 180; // 0 = only the first open of each day
  bool connectOnOpen = false;
  bool clipboardWatch = true;
  bool httpsOnly = true;
  String pingMode = 'tcp';
  String testUrl = 'http://connectivitycheck.gstatic.com/generate_204';
  String dns = 'google';
  bool ipv6 = false;
  bool fragment = false;
  bool mux = false;
  bool blockAds = false;
  bool announceOn = true;
  bool winAutostart = false;
  String sysJson = '[]'; // messages the app writes itself (e.g. new version)
  int updNotified = 0;
  int annRead = -1; // -1 = announcements never initialised yet
  Set<int> annReadIds = {};
  Set<int> annDeleted = {};
  String warnedDay = '';
  String warnDismissDay = '';
  String annJson = '[]';
  bool blockQuic = true; // QUIC (UDP 443) is slow through proxies; apps fall back to TCP
  int mtu = 1500;
  bool panelTuning = false; // use the panel's own fragment/mux (slower, for strict filtering)

  /// Back to the recommended defaults (servers, subscriptions and per-app choices are kept).
  void resetSettings() {
    bypassIran = true;
    autoSelect = true;
    autoUpdate = true;
    updateEveryMin = 180;
    connectOnOpen = false;
    clipboardWatch = true;
    httpsOnly = true;
    pingMode = 'tcp';
    testUrl = 'http://connectivitycheck.gstatic.com/generate_204';
    dns = 'google';
    ipv6 = false;
    fragment = false;
    mux = false;
    blockAds = false;
    panelTuning = false;
    blockQuic = true;
    mtu = 1500;
    announceOn = true;
  }

  // Sensitive data (servers, subscription links) goes to the Android Keystore-backed
  // secure storage; falls back to plain prefs only if secure storage is unavailable.
  Future<String?> _getSecret(String k) async {
    if (Platform.isWindows) return _p.getString(k);
    try {
      final v = await _sec.read(key: k);
      if (v != null) return v;
    } catch (_) {}
    return _p.getString(k);
  }

  Future<void> _putSecret(String k, String v) async {
    if (Platform.isWindows) {
      await _p.setString(k, v);
      return;
    }
    try {
      await _sec.write(key: k, value: v);
      if (await _sec.read(key: k) == v) {
        await _p.remove(k);
        return;
      }
    } catch (_) {}
    await _p.setString(k, v);
  }

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = await _getSecret('nodes');
    if (raw != null) {
      try {
        nodes = (jsonDecode(raw) as List)
            .map((e) => Node.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        nodes = [];
      }
    }
    final sraw = await _getSecret('subs_json');
    if (sraw != null) {
      try {
        subs = (jsonDecode(sraw) as List).map((e) => e.toString()).toList();
      } catch (_) {
        subs = [];
      }
    } else {
      subs = _p.getStringList('subs') ?? []; // legacy
    }
    selected = _p.getInt('selected') ?? 0;
    updatedMs = _p.getInt('updatedMs') ?? 0;
    lastClip = _p.getString('lastClip') ?? '';
    subTitle = _p.getString('subTitle') ?? '';
    perAppMode = _p.getString('perAppMode') ?? 'all';
    perAppList = (_p.getStringList('perAppList') ?? <String>[]).toSet();

    bypassIran = _p.getBool('bypassIran') ?? true;
    autoSelect = _p.getBool('autoSelect') ?? true;
    autoUpdate = _p.getBool('autoUpdate') ?? true;
    updateEveryMin = _p.getInt('updateEveryMin') ?? 180;
    connectOnOpen = _p.getBool('connectOnOpen') ?? false;
    clipboardWatch = _p.getBool('clipboardWatch') ?? true;
    httpsOnly = _p.getBool('httpsOnly') ?? true;
    pingMode = _p.getString('pingMode') ?? 'tcp';
    testUrl = _p.getString('testUrl') ?? 'http://connectivitycheck.gstatic.com/generate_204';
    dns = _p.getString('dns') ?? 'google';
    ipv6 = _p.getBool('ipv6') ?? false;
    announceOn = _p.getBool('announceOn') ?? true;
    winAutostart = _p.getBool('winAutostart') ?? false;
    sysJson = _p.getString('sysJson') ?? '[]';
    updNotified = _p.getInt('updNotified') ?? 0;
    annRead = _p.getInt('annRead') ?? -1;
    annReadIds = (_p.getStringList('annReadIds') ?? <String>[]).map(int.tryParse).whereType<int>().toSet();
    annDeleted = (_p.getStringList('annDeleted') ?? <String>[]).map(int.tryParse).whereType<int>().toSet();
    warnedDay = _p.getString('warnedDay') ?? '';
    warnDismissDay = _p.getString('warnDismissDay') ?? '';
    annJson = _p.getString('annJson') ?? '[]';
    fragment = _p.getBool('fragment') ?? false;
    mux = _p.getBool('mux') ?? false;
    blockAds = _p.getBool('blockAds') ?? false;
    panelTuning = _p.getBool('panelTuning') ?? false;
    blockQuic = _p.getBool('blockQuic') ?? true;
    mtu = _p.getInt('mtu') ?? 1500;

    final inf = _p.getString('subinfo');
    if (inf != null) {
      try {
        info = SubInfo.fromJson(Map<String, dynamic>.from(jsonDecode(inf) as Map));
      } catch (_) {}
    }
    if (selected >= nodes.length) selected = 0;
    Node.pingMode = pingMode;
  }

  Future<void> save() async {
    Node.pingMode = pingMode;
    await _putSecret('nodes', jsonEncode(nodes.map((e) => e.toJson()).toList()));
    await _putSecret('subs_json', jsonEncode(subs));
    await _p.remove('subs');
    await _p.setInt('selected', selected);
    await _p.setInt('updatedMs', updatedMs);
    await _p.setString('lastClip', lastClip);
    await _p.setString('subTitle', subTitle);
    await _p.setString('perAppMode', perAppMode);
    await _p.setStringList('perAppList', perAppList.toList());

    await _p.setBool('bypassIran', bypassIran);
    await _p.setBool('autoSelect', autoSelect);
    await _p.setBool('autoUpdate', autoUpdate);
    await _p.setInt('updateEveryMin', updateEveryMin);
    await _p.setBool('connectOnOpen', connectOnOpen);
    await _p.setBool('clipboardWatch', clipboardWatch);
    await _p.setBool('httpsOnly', httpsOnly);
    await _p.setString('pingMode', pingMode);
    await _p.setString('testUrl', testUrl);
    await _p.setString('dns', dns);
    await _p.setBool('ipv6', ipv6);
    await _p.setBool('fragment', fragment);
    await _p.setBool('mux', mux);
    await _p.setBool('blockAds', blockAds);
    await _p.setBool('panelTuning', panelTuning);
    await _p.setBool('blockQuic', blockQuic);
    await _p.setInt('mtu', mtu);
    await _p.setBool('announceOn', announceOn);
    await _p.setBool('winAutostart', winAutostart);
    await _p.setString('sysJson', sysJson);
    await _p.setInt('updNotified', updNotified);
    await _p.setInt('annRead', annRead);
    await _p.setStringList('annReadIds', annReadIds.map((e) => '$e').toList());
    await _p.setStringList('annDeleted', annDeleted.map((e) => '$e').toList());
    await _p.setString('warnedDay', warnedDay);
    await _p.setString('warnDismissDay', warnDismissDay);
    await _p.setString('annJson', annJson);
    if (info != null) {
      await _p.setString('subinfo', jsonEncode(info!.toJson()));
    } else {
      await _p.remove('subinfo');
    }
  }
}
