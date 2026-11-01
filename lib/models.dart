import 'dart:convert';
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

class Node {
  final Map<String, dynamic> ob;
  final String src; // 'sub' or 'manual'
  int? delay;
  bool tested = false;
  Node(this.ob, this.src);

  String get name => (ob['tag'] ?? ob['protocol'] ?? 'node').toString();
  String get key => '$name|$address';
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

  String get address {
    final s = ob['settings'];
    if (s is Map) {
      final v = s['vnext'];
      if (v is List && v.isNotEmpty && v[0] is Map) {
        return '${(v[0] as Map)['address']}:${(v[0] as Map)['port']}';
      }
      final sv = s['servers'];
      if (sv is List && sv.isNotEmpty && sv[0] is Map) {
        return '${(sv[0] as Map)['address']}:${(sv[0] as Map)['port']}';
      }
      if (s['address'] != null) return '${s['address']}:${s['port']}';
    }
    return '';
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

  Map<String, dynamic> toJson() => {'ob': ob, 'src': src, 'd': delay, 't': tested};

  factory Node.fromJson(Map<String, dynamic> j) {
    final n = Node(Map<String, dynamic>.from(j['ob'] as Map), (j['src'] ?? 'manual').toString());
    n.delay = j['d'] is int ? j['d'] as int : null;
    n.tested = j['t'] == true;
    return n;
  }
}

class Store {
  late SharedPreferences _p;
  List<Node> nodes = [];
  List<String> subs = [];
  int selected = 0;
  bool bypassIran = true;
  SubInfo? info;
  int updatedMs = 0;
  String perAppMode = 'all'; // all | include | exclude
  Set<String> perAppList = {};

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    final raw = _p.getString('nodes');
    if (raw != null) {
      try {
        nodes = (jsonDecode(raw) as List)
            .map((e) => Node.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      } catch (_) {
        nodes = [];
      }
    }
    subs = _p.getStringList('subs') ?? [];
    selected = _p.getInt('selected') ?? 0;
    bypassIran = _p.getBool('bypassIran') ?? true;
    updatedMs = _p.getInt('updatedMs') ?? 0;
    perAppMode = _p.getString('perAppMode') ?? 'all';
    perAppList = (_p.getStringList('perAppList') ?? <String>[]).toSet();
    final inf = _p.getString('subinfo');
    if (inf != null) {
      try {
        info = SubInfo.fromJson(Map<String, dynamic>.from(jsonDecode(inf) as Map));
      } catch (_) {}
    }
    if (selected >= nodes.length) selected = 0;
  }

  Future<void> save() async {
    await _p.setString('nodes', jsonEncode(nodes.map((e) => e.toJson()).toList()));
    await _p.setStringList('subs', subs);
    await _p.setInt('selected', selected);
    await _p.setBool('bypassIran', bypassIran);
    await _p.setInt('updatedMs', updatedMs);
    await _p.setString('perAppMode', perAppMode);
    await _p.setStringList('perAppList', perAppList.toList());
    if (info != null) {
      await _p.setString('subinfo', jsonEncode(info!.toJson()));
    } else {
      await _p.remove('subinfo');
    }
  }
}
