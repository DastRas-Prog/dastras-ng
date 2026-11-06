import 'dart:convert';
import 'models.dart';

const kDns = <String, List<String>>{
  'cloudflare': ['1.1.1.1', '1.0.0.1'],
  'google': ['8.8.8.8', '8.8.4.4'],
  'quad9': ['9.9.9.9', '149.112.112.112'],
  'adguard': ['94.140.14.14', '94.140.15.15'],
};

const kDnsNames = <String, String>{
  'cloudflare': 'Cloudflare (1.1.1.1)',
  'google': 'Google (8.8.8.8)',
  'quad9': 'Quad9 (9.9.9.9)',
  'adguard': 'AdGuard (94.140.14.14)',
};

List<String> dnsList(Store s) => kDns[s.dns] ?? kDns['cloudflare']!;

String _flow(Map<String, dynamic> ob) {
  try {
    final u = ((ob['settings'] as Map)['vnext'] as List)[0]['users'][0] as Map;
    return (u['flow'] ?? '').toString();
  } catch (_) {
    return '';
  }
}

/// Builds the full Xray config around the selected outbound.
/// The TUN fd and asset dir are injected natively (root "env").
String buildConfig(Map<String, dynamic> ob, Store s) {
  final proxy = Map<String, dynamic>.from(ob)..['tag'] = 'proxy';
  final extra = proxy.remove('_extra');
  final outbounds = <Map<String, dynamic>>[];

  final stream = proxy['streamSettings'] is Map
      ? Map<String, dynamic>.from(proxy['streamSettings'] as Map)
      : <String, dynamic>{};
  final sec = (stream['security'] ?? '').toString();

  // Panel-provided fragment / mux slow down every connection, so they are only kept
  // when the user asks for them (strict filtering).
  if (!s.panelTuning) {
    proxy.remove('mux');
    if (stream['sockopt'] is Map) {
      final so = Map<String, dynamic>.from(stream['sockopt'] as Map)..remove('dialerProxy');
      if (so.isEmpty) {
        stream.remove('sockopt');
      } else {
        stream['sockopt'] = so;
      }
      proxy['streamSettings'] = stream;
    }
  }

  final sockNow = stream['sockopt'] is Map ? stream['sockopt'] as Map : const {};
  final serverTuned = s.panelTuning && sockNow['dialerProxy'] != null; // panel (e.g. Marzban) already set fragment/noise

  // TLS fragmentation: splits the TLS hello so DPI can't read the SNI.
  if (serverTuned) {
    outbounds.add(proxy);
    if (extra is List) {
      for (final e in extra) {
        outbounds.add(Map<String, dynamic>.from(e as Map));
      }
    }
  } else if (s.fragment && (sec == 'tls' || sec == 'reality')) {
    final sock = stream['sockopt'] is Map
        ? Map<String, dynamic>.from(stream['sockopt'] as Map)
        : <String, dynamic>{};
    sock['dialerProxy'] = 'fragment';
    stream['sockopt'] = sock;
    proxy['streamSettings'] = stream;
    outbounds.add(proxy);
    outbounds.add({
      'tag': 'fragment',
      'protocol': 'freedom',
      'settings': {
        'fragment': {'packets': 'tlshello', 'length': '100-200', 'interval': '10-20'}
      },
      'streamSettings': {
        'sockopt': {'tcpNoDelay': true}
      }
    });
  } else {
    outbounds.add(proxy);
  }

  // Mux is incompatible with XTLS Vision flows.
  final p = (proxy['protocol'] ?? '').toString();
  if (s.mux && !proxy.containsKey('mux') && (p == 'vless' || p == 'vmess' || p == 'trojan') && _flow(proxy).isEmpty) {
    proxy['mux'] = {'enabled': true, 'concurrency': 8};
  }

  if (!outbounds.any((o) => o['tag'] == 'direct')) outbounds.add({'tag': 'direct', 'protocol': 'freedom'});
  if (!outbounds.any((o) => o['tag'] == 'block')) outbounds.add({'tag': 'block', 'protocol': 'blackhole'});

  final rules = <Map<String, dynamic>>[
    if (s.blockQuic)
      {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'},
    if (s.blockAds)
      {'type': 'field', 'domain': ['geosite:category-ads-all'], 'outboundTag': 'block'},
    {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'direct'},
    if (s.bypassIran) ...[
      {'type': 'field', 'domain': ['geosite:category-ir'], 'outboundTag': 'direct'},
      {'type': 'field', 'ip': ['geoip:ir'], 'outboundTag': 'direct'},
    ],
  ];

  final cfg = {
    'log': {'loglevel': 'warning'},
    'dns': {'servers': dnsList(s), 'queryStrategy': s.ipv6 ? 'UseIP' : 'UseIPv4'},
    'inbounds': [
      {
        'tag': 'tun-in',
        'protocol': 'tun',
        'settings': {'name': 'xray0', 'MTU': s.mtu},
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls', 'quic']
        }
      }
    ],
    'outbounds': outbounds,
    // AsIs avoids extra DNS lookups when no geoip rules are in use.
    'routing': {'domainStrategy': s.bypassIran ? 'IPIfNonMatch' : 'AsIs', 'rules': rules},
  };
  return jsonEncode(cfg);
}
