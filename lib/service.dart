import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;
import 'dart:math' as math;
import 'package:http/http.dart' as http;
import 'core.dart';
import 'lang.dart';
import 'models.dart';
import 'share_links.dart';

/// Latency test targets for "Real" mode.
const kTestUrls = <String, String>{
  'http://cp.cloudflare.com/': 'Cloudflare',
  'http://www.gstatic.com/generate_204': 'Google',
  'http://connectivitycheck.gstatic.com/generate_204': 'Google (connectivity)',
  'https://github.com/': 'GitHub',
  'https://www.reddit.com/': 'Reddit',
};

// Panels answer differently depending on the client. Plain share links (unknown client)
// give light, fast configs; Happ/v2rayNG-style clients may get the panel's JSON with
// fragment/mux baked in.
const _linkAgents = ['DastRasNG/1.4', 'v2rayNG/1.9.0', 'Happ/1.0', 'Hiddify/2.5.7'];
const _jsonAgents = ['Happ/1.0', 'v2rayNG/1.9.0', 'Hiddify/2.5.7', 'DastRasNG/1.4'];

const _notProxy = {'freedom', 'blackhole', 'dns', 'loopback'};

/// Converts share links / subscription text / Xray JSON into outbounds.
Future<List<Map<String, dynamic>>> convert(String text) async {
  final t = text.trim();
  if (t.startsWith('{') || t.startsWith('[')) {
    final j = _fromJson(t);
    if (j.isNotEmpty) return j;
  }
  // 1) the native converter, 2) the built-in parser for every link the converter skipped
  var viaCore = <Map<String, dynamic>>[];
  try {
    final r = await Core.invoke('convertShareLinksToXrayJson', {'text': text});
    final data = r['data'];
    final list = (r['success'] == true && data is Map ? data['outbounds'] : null) as List?;
    if (list != null) viaCore = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  } catch (_) {}
  String keyOf(Map<String, dynamic> o) => '${o['protocol']}|${Node(o, 'x').address}';
  final have = {for (final o in viaCore) keyOf(o)};
  final out = [...viaCore];
  for (final o in parseShareText(text)) {
    if (!have.contains(keyOf(o))) out.add(o);
  }
  if (out.isEmpty) throw Exception('no usable config');
  return out;
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
  final String? fallbackUrl; // backup address (Happ: fallback-url)
  final String? movedTo; // new address (Hiddify: moved-permanently-to)
  SubParsed(this.obs, this.info, {this.title, this.supportUrl, this.fallbackUrl, this.movedTo});
}

String? _decodeTitle(String? h) {
  if (h == null || h.isEmpty) return null;
  try {
    if (h.startsWith('base64:')) return utf8.decode(base64.decode(h.substring(7).trim()));
  } catch (_) {}
  return h;
}

class _Resp {
  final int statusCode;
  final String body;
  final Map<String, String> headers;
  _Resp(this.statusCode, this.body, this.headers);
}

/// Normal request first; if the address is blocked or its DNS is poisoned, resolve the name over
/// DNS-over-HTTPS and talk to the real IP directly (the certificate is still checked for the real name).
Future<_Resp> _get(String url, String ua, {int depth = 0}) async {
  Object? first;
  try {
    final r = await http.get(Uri.parse(url), headers: {'User-Agent': ua}).timeout(const Duration(seconds: 12));
    return _Resp(r.statusCode, r.body, r.headers);
  } catch (e) {
    first = e;
  }
  try {
    return await _getViaDoh(url, ua, depth);
  } catch (_) {}
  throw first ?? Exception('unreachable');
}

Future<_Resp> _getViaDoh(String url, String ua, int depth) async {
  final u = Uri.parse(url);
  final https = u.scheme == 'https';
  final port = u.hasPort ? u.port : (https ? 443 : 80);
  final ips = await _doh(u.host);
  if (ips.isEmpty) throw Exception('dns');
  Object? last;
  for (final ip in ips.take(3)) {
    try {
      var s = await Socket.connect(ip, port, timeout: const Duration(seconds: 8));
      if (https) s = await SecureSocket.secure(s, host: u.host);
      final path = (u.path.isEmpty ? '/' : u.path) + (u.hasQuery ? '?${u.query}' : '');
      s.write('GET $path HTTP/1.1\r\nHost: ${u.host}${u.hasPort ? ':${u.port}' : ''}\r\n'
          'User-Agent: $ua\r\nAccept: */*\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n');
      await s.flush();
      final bytes = BytesBuilder(copy: false);
      await for (final c in s.timeout(const Duration(seconds: 20))) {
        bytes.add(c);
      }
      s.destroy();
      final r = _parseRaw(bytes.takeBytes());
      final loc = r.headers['location'];
      if ({301, 302, 307, 308}.contains(r.statusCode) && loc != null && depth < 3) {
        return _get(u.resolve(loc).toString(), ua, depth: depth + 1);
      }
      return r;
    } catch (e) {
      last = e;
    }
  }
  throw last ?? Exception('unreachable');
}

Future<List<String>> _doh(String host) async {
  const urls = [
    'https://1.1.1.1/dns-query?name=%s&type=A',
    'https://8.8.8.8/resolve?name=%s&type=A',
    'https://dns.google/resolve?name=%s&type=A',
  ];
  for (final t in urls) {
    try {
      final r = await http
          .get(Uri.parse(t.replaceFirst('%s', host)), headers: {'accept': 'application/dns-json'})
          .timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) continue;
      final j = jsonDecode(r.body) as Map;
      final ips = <String>[
        for (final a in (j['Answer'] as List? ?? const []))
          if (a is Map && a['type'] == 1) '${a['data']}'
      ];
      if (ips.isNotEmpty) return ips;
    } catch (_) {}
  }
  return [];
}

_Resp _parseRaw(List<int> b) {
  var idx = -1;
  for (var k = 0; k + 3 < b.length; k++) {
    if (b[k] == 13 && b[k + 1] == 10 && b[k + 2] == 13 && b[k + 3] == 10) {
      idx = k;
      break;
    }
  }
  if (idx < 0) throw Exception('bad response');
  final head = utf8.decode(b.sublist(0, idx), allowMalformed: true).split('\r\n');
  final parts = head.first.split(' ');
  final status = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final headers = <String, String>{};
  for (final l in head.skip(1)) {
    final c = l.indexOf(':');
    if (c > 0) headers[l.substring(0, c).trim().toLowerCase()] = l.substring(c + 1).trim();
  }
  var body = b.sublist(idx + 4);
  if ((headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked')) body = _dechunk(body);
  return _Resp(status, utf8.decode(body, allowMalformed: true), headers);
}

List<int> _dechunk(List<int> b) {
  final out = <int>[];
  var i = 0;
  while (i < b.length) {
    var e = i;
    while (e + 1 < b.length && !(b[e] == 13 && b[e + 1] == 10)) {
      e++;
    }
    if (e + 1 >= b.length) break;
    final size = int.tryParse(utf8.decode(b.sublist(i, e)).split(';').first.trim(), radix: 16) ?? 0;
    if (size == 0) break;
    final start = e + 2;
    final end = start + size;
    if (end > b.length) {
      out.addAll(b.sublist(start));
      break;
    }
    out.addAll(b.sublist(start, end));
    i = end + 2;
  }
  return out;
}

Future<SubParsed> _fetchOne(String url, {bool preferJson = false}) async {
  Object? last;
  for (final ua in (preferJson ? _jsonAgents : _linkAgents)) {
    try {
      final res = await _get(url, ua);
      if (res.statusCode != 200) {
        last = Exception('HTTP ${res.statusCode}');
        continue;
      }
      if (res.body.trimLeft().startsWith('<')) {
        last = Exception('not a subscription'); // a web page, not a subscription
        continue;
      }
      final obs = await convert(res.body);
      return SubParsed(
        obs,
        parseUserInfo(res.headers['subscription-userinfo']),
        title: _decodeTitle(res.headers['profile-title']),
        supportUrl: res.headers['support-url'],
        fallbackUrl: res.headers['fallback-url'],
        movedTo: res.headers['moved-permanently-to'],
      );
    } catch (e) {
      last = e;
    }
  }
  throw last ?? Exception('subscription failed');
}

/// Backup address written after the name: https://site/sub#Name?fallback-url=<encoded url>
String? _fragmentFallback(String url) {
  final f = Uri.tryParse(url)?.fragment ?? '';
  final i = f.indexOf('fallback-url=');
  if (i < 0) return null;
  var v = f.substring(i + 13);
  final amp = v.indexOf('&');
  if (amp >= 0) v = v.substring(0, amp);
  try {
    final d = Uri.decodeComponent(v);
    return d.startsWith('http') ? d : null;
  } catch (_) {
    return null;
  }
}

/// Reads the subscription; if the main address fails, tries the backup address (if there is one).
Future<SubParsed> fetchAndParse(String url, {bool preferJson = false, String? fallback}) async {
  try {
    return await _fetchOne(url, preferJson: preferJson);
  } catch (e) {
    final fb = fallback ?? _fragmentFallback(url);
    if (fb != null && fb != url) {
      try {
        return await _fetchOne(fb, preferJson: preferJson);
      } catch (_) {}
    }
    rethrow;
  }
}

// ---------- which provider is the user on? ----------

String friendlyIsp(String s) {
  final l = s.toLowerCase();
  const m = <String, List<String>>{
    'mobile communication company of iran': ['همراه اول', 'Hamrah-e-Aval'],
    'irancell': ['ایرانسل', 'Irancell'],
    'rightel': ['رایتل', 'Rightel'],
    'telecommunication company of iran': ['مخابرات (ADSL / فیبر)', 'TCI (ADSL / fiber)'],
    'shatel': ['شاتل', 'Shatel'],
    'pars online': ['پارس‌آنلاین', 'Pars Online'],
    'asiatech': ['آسیاتک', 'Asiatech'],
    'respina': ['رسپینا', 'Respina'],
    'hiweb': ['های‌وب', 'HiWeb'],
    'mobinnet': ['مبین‌نت', 'MobinNet'],
    'samantel': ['سامانتل', 'Samantel'],
    'afranet': ['افرانت', 'Afranet'],
    'andishe sabz': ['اندیشه سبز', 'Andishe Sabz'],
  };
  for (final e in m.entries) {
    if (l.contains(e.key)) return isFa ? e.value[0] : e.value[1];
  }
  return s;
}

/// Asks a public IP service for the provider name. Only meaningful while the VPN is off.
Future<String?> lookupIsp() async {
  for (final u in ['https://ipwho.is/', 'http://ip-api.com/json/?fields=status,isp,org']) {
    try {
      final r = await http.get(Uri.parse(u)).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) continue;
      final j = jsonDecode(r.body) as Map;
      final c = j['connection'];
      final raw = c is Map ? '${c['isp'] ?? c['org'] ?? ''}' : '${j['isp'] ?? j['org'] ?? ''}';
      if (raw.isNotEmpty) return friendlyIsp(raw);
    } catch (_) {}
  }
  return null;
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

/// Real delay = one HTTP round trip through the server (like Hiddify), so every protocol is compared fairly.
/// Four servers per round; a server that does not answer on one test URL gets the next URL
/// (one URL can be blocked on some networks). [onResult] fires after every round.
Future<void> pingReal(List<Node> nodes, String url, {void Function()? onResult}) async {
  final urls = <String>{url, 'http://cp.cloudflare.com/generate_204', 'https://www.gstatic.com/generate_204'}.toList();
  for (var i = 0; i < nodes.length; i += 4) {
    final chunk = nodes.sublist(i, math.min(i + 4, nodes.length));
    final best = List<int?>.filled(chunk.length, null);
    for (final u in urls) {
      final todo = [
        for (var k = 0; k < chunk.length; k++)
          if (best[k] == null) k
      ];
      if (todo.isEmpty) break;
      try {
        final res = await pingBatch(todo.map((k) => chunk[k].ob).toList(), u);
        for (var j = 0; j < todo.length && j < res.length; j++) {
          final v = res[j];
          best[todo[j]] = (v == null || v <= 0 || v >= 99999) ? null : v;
        }
      } catch (_) {}
    }
    for (var k = 0; k < chunk.length; k++) {
      chunk[k].real = best[k];
    }
    onResult?.call();
  }
}

/// TCP connect time to the server itself (DNS excluded). Works even while connected,
/// because this app is excluded from the VPN.
final Map<String, InternetAddress> _dnsCache = {};

Future<TcpStat?> _tcp(Node n, int samples) async {
  final e = n.endpoint;
  if (e == null) return null;
  InternetAddress? addr = _dnsCache[e.$1] ?? InternetAddress.tryParse(e.$1);
  if (addr == null) {
    try {
      final l = await InternetAddress.lookup(e.$1).timeout(const Duration(seconds: 3));
      if (l.isEmpty) return const TcpStat(0, 1, 0, 0, 0);
      addr = l.first;
      _dnsCache[e.$1] = addr;
    } catch (_) {
      return TcpStat(0, samples, 0, 0, 0);
    }
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

Future<TcpStat?> tcpStat(Node n, int samples) => _tcp(n, samples);

/// Tests the servers a few at a time; [onResult] fires as soon as each one is done,
/// so the list can show (and re-order) results one by one instead of waiting for all of them.
Future<void> tcpPingAll(List<Node> nodes, {int samples = 2, void Function()? onResult, int concurrency = 6}) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final k = next++;
      if (k >= nodes.length) return;
      TcpStat? st;
      try {
        st = await _tcp(nodes[k], samples);
      } catch (_) {}
      nodes[k].stat = st;
      nodes[k].tcp = (st != null && st.ok > 0) ? st.min : null;
      nodes[k].tested = true;
      onResult?.call();
    }
  }

  await Future.wait([for (var w = 0; w < math.min(concurrency, nodes.length); w++) worker()]);
}

/// Real (URL) delay, three servers per round, reporting after every round.
Future<void> pingReal(List<Node> nodes, String url, {void Function()? onResult}) async {
  for (var i = 0; i < nodes.length; i += 3) {
    final chunk = nodes.sublist(i, math.min(i + 3, nodes.length));
    final res = await pingBatch(chunk.map((n) => n.ob).toList(), url);
    for (var k = 0; k < chunk.length; k++) {
      chunk[k].real = k < res.length ? res[k] : null;
    }
    onResult?.call();
  }
}
