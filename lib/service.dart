import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'core.dart';
import 'models.dart';

/// Latency test targets for "Real" mode.
const kTestUrls = <String, String>{
  'http://cp.cloudflare.com/': 'Cloudflare',
  'http://www.gstatic.com/generate_204': 'Google',
  'http://connectivitycheck.gstatic.com/generate_204': 'Google (connectivity)',
  'https://github.com/': 'GitHub',
  'https://www.reddit.com/': 'Reddit',
};

// Some panels answer differently depending on the client, so try several.
const _userAgents = ['Happ/1.0', 'v2rayNG/1.9.0', 'Hiddify/2.5.7', 'DastRasNG/1.3'];

const _notProxy = {'freedom', 'blackhole', 'dns', 'loopback'};

/// Converts share links / subscription text / Xray JSON into outbounds.
Future<List<Map<String, dynamic>>> convert(String text) async {
  final t = text.trim();
  if (t.startsWith('{') || t.startsWith('[')) {
    final j = _fromJson(t);
    if (j.isNotEmpty) return j;
  }
  final r = await Core.invoke('convertShareLinksToXrayJson', {'text': text});
  if (r['success'] != true) {
    throw Exception((r['error'] ?? 'convert failed').toString());
  }
  final data = r['data'];
  final list = (data is Map ? data['outbounds'] : null) as List?;
  if (list == null || list.isEmpty) throw Exception('no usable config');
  return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
}

/// Helper outbounds (fragment, noise, chained proxies...) that [chosen] depends on
/// through sockopt.dialerProxy / proxySettings.
List<Map<String, dynamic>> _extras(Map chosen, List all) {
  final byTag = <String, Map<String, dynamic>>{};
  for (final o in all) {
    if (o is Map && o['tag'] != null) byTag[o['tag'].toString()] = Map<String, dynamic>.from(o);
  }
  final out = <Map<String, dynamic>>[];
  final seen = <String>{};
  void visit(Map o) {
    final ss = o['streamSettings'];
    final sock = ss is Map ? ss['sockopt'] : null;
    final dp = sock is Map ? sock['dialerProxy'] : null;
    final ps = o['proxySettings'] is Map ? (o['proxySettings'] as Map)['tag'] : null;
    for (final t in [dp, ps]) {
      if (t == null) continue;
      final k = t.toString();
      if (seen.add(k) && byTag.containsKey(k)) {
        out.add(byTag[k]!);
        visit(byTag[k]!);
      }
    }
  }

  visit(chosen);
  return out;
}

/// Full Xray JSON configs (single, or an array as Marzban's /v2ray-json serves) -> proxy outbounds.
List<Map<String, dynamic>> _fromJson(String t) {
  try {
    final d = jsonDecode(t);
    final configs = d is List ? d : [d];
    final out = <Map<String, dynamic>>[];
    for (final c in configs) {
      if (c is! Map) continue;
      final name = (c['remarks'] ?? c['ps'] ?? c['name'] ?? '').toString();
      final obs = c['outbounds'];
      if (obs is List) {
        for (final o in obs) {
          if (o is Map && !_notProxy.contains((o['protocol'] ?? '').toString())) {
            final m = Map<String, dynamic>.from(o);
            final ex = _extras(m, obs);
            if (ex.isNotEmpty) m['_extra'] = ex;
            if (name.isNotEmpty) m['tag'] = name;
            out.add(m);
            break;
          }
        }
      } else if (c['protocol'] != null && !_notProxy.contains(c['protocol'].toString())) {
        out.add(Map<String, dynamic>.from(c));
      }
    }
    return out;
  } catch (_) {
    return [];
  }
}

class SubParsed {
  final List<Map<String, dynamic>> obs;
  final SubInfo? info;
  final String? title; // profile-title header
  final String? supportUrl; // support-url header
  SubParsed(this.obs, this.info, {this.title, this.supportUrl});
}

String? _decodeTitle(String? h) {
  if (h == null || h.isEmpty) return null;
  try {
    if (h.startsWith('base64:')) return utf8.decode(base64.decode(h.substring(7).trim()));
  } catch (_) {}
  return h;
}

Future<SubParsed> fetchAndParse(String url) async {
  Object? last;
  for (final ua in _userAgents) {
    try {
      final res = await http
          .get(Uri.parse(url), headers: {'User-Agent': ua})
          .timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) {
        last = Exception('HTTP ${res.statusCode}');
        continue;
      }
      final obs = await convert(res.body);
      return SubParsed(
        obs,
        parseUserInfo(res.headers['subscription-userinfo']),
        title: _decodeTitle(res.headers['profile-title']),
        supportUrl: res.headers['support-url'],
      );
    } catch (e) {
      last = e;
    }
  }
  throw last ?? Exception('subscription failed');
}

SubInfo? parseUserInfo(String? h) {
  if (h == null || h.isEmpty) return null;
  final m = <String, int>{};
  for (final part in h.split(';')) {
    final kv = part.trim().split('=');
    if (kv.length == 2) m[kv[0].trim()] = int.tryParse(kv[1].trim()) ?? 0;
  }
  return SubInfo((m['upload'] ?? 0) + (m['download'] ?? 0), m['total'] ?? 0, m['expire'] ?? 0);
}

List<Map<String, dynamic>> _pingOutbounds(Map<String, dynamic> ob) {
  final m = Map<String, dynamic>.from(ob);
  final ex = m.remove('_extra');
  return [m, if (ex is List) ...ex.map((e) => Map<String, dynamic>.from(e as Map))];
}

/// Real (URL) delay through the proxy. Max 5 configs per batch.
/// Only works while the VPN is disconnected.
Future<List<int?>> pingBatch(List<Map<String, dynamic>> obs, String url) async {
  final out = <int?>[];
  for (var i = 0; i < obs.length; i += 5) {
    final chunk = obs.sublist(i, math.min(i + 5, obs.length));
    final r = await Core.invoke('pingBatch', {
      'configs': [
        for (final ob in chunk)
          {
            'xrayJson': jsonEncode({'outbounds': _pingOutbounds(ob)})
          }
      ],
      'timeout': 5,
      'url': url,
    });
    List items = const [];
    final d = r['data'];
    if (d is List) {
      items = d;
    } else if (d is Map) {
      items = (d['results'] ?? d['items'] ?? d['delays'] ?? d['configs'] ?? const []) as List;
    }
    for (var k = 0; k < chunk.length; k++) {
      int? v;
      if (k < items.length && items[k] is Map) {
        final dl = (items[k] as Map)['delay'];
        if (dl is num && dl > 0 && dl < 10000) v = dl.toInt();
      }
      out.add(v);
    }
  }
  return out;
}

/// TCP connect time to the server itself (DNS excluded). Works even while connected,
/// because this app is excluded from the VPN.
Future<TcpStat?> _tcp(Node n, int samples) async {
  final e = n.endpoint;
  if (e == null) return null;
  InternetAddress addr;
  try {
    final l = await InternetAddress.lookup(e.$1).timeout(const Duration(seconds: 3));
    if (l.isEmpty) return const TcpStat(0, 1, 0, 0, 0);
    addr = l.first;
  } catch (_) {
    return TcpStat(0, samples, 0, 0, 0);
  }
  final t = <int>[];
  for (var i = 0; i < samples; i++) {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(addr, e.$2, timeout: const Duration(milliseconds: 2500));
      sw.stop();
      s.destroy();
      t.add(sw.elapsedMilliseconds);
    } catch (_) {}
  }
  if (t.isEmpty) return TcpStat(0, samples, 0, 0, 0);
  final sum = t.fold<int>(0, (a, b) => a + b);
  return TcpStat(t.length, samples, t.reduce(math.min), t.reduce(math.max), sum / t.length);
}

/// Tests every node in parallel (16 at a time) and stores the result on the nodes.
Future<void> tcpPingAll(List<Node> nodes, {int samples = 2}) async {
  for (var i = 0; i < nodes.length; i += 16) {
    final end = math.min(i + 16, nodes.length);
    await Future.wait([
      for (var k = i; k < end; k++)
        _tcp(nodes[k], samples).then((s) {
          nodes[k].stat = s;
          nodes[k].tcp = (s != null && s.ok > 0) ? s.min : null;
          nodes[k].tested = true;
        })
    ]);
  }
}
