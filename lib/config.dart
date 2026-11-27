import 'dart:convert';
import 'platform.dart';
import 'dart:io' show Platform;
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
String buildConfig(Map<String, dynamic> ob, Store s, {List<Map<String, dynamic>> pool = const []}) {
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

  // lower latency and better throughput for small packets on TCP based transports
  const tcpLike = {'tcp', 'ws', 'xhttp', 'grpc', 'httpupgrade', 'http'};
  if (stream.isNotEmpty && tcpLike.contains((stream['network'] ?? 'tcp').toString())) {
    final so = stream['sockopt'] is Map ? Map<String, dynamic>.from(stream['sockopt'] as Map) : <String, dynamic>{};
    so.putIfAbsent('tcpNoDelay', () => true);
    stream['sockopt'] = so;
    proxy['streamSettings'] = stream;
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
  if (s.mux && !proxy.containsKey('mux') && (p == 'vless' || p == 'vmess' || p == 'trojan') && _flow(proxy).isEmpty &&
      !const {'xhttp', 'grpc', 'hysteria', 'kcp'}.contains((stream['network'] ?? 'tcp').toString())) {
    proxy['mux'] = {'enabled': true, 'concurrency': 8};
  }

  if (!outbounds.any((o) => o['tag'] == 'direct')) outbounds.add({'tag': 'direct', 'protocol': 'freedom'});
  if (!outbounds.any((o) => o['tag'] == 'block')) outbounds.add({'tag': 'block', 'protocol': 'blackhole'});

  final win = isDesktop;
  // Windows: choose programs by process name (works for programs that use the system proxy)
  final names = <String>[
    for (final n in s.perAppList) ...[n, if (!n.toLowerCase().endsWith('.exe')) '$n.exe']
  ];
  final winInclude = win && s.perAppMode == 'include' && s.perAppList.isNotEmpty;
  final winExclude = win && s.perAppMode == 'exclude' && s.perAppList.isNotEmpty;
  final rules = <Map<String, dynamic>>[
    if (win) {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
    if (winExclude) {'type': 'field', 'process': names, 'outboundTag': 'direct'},
    if (s.blockQuic)
      {'type': 'field', 'network': 'udp', 'port': '443', 'outboundTag': 'block'},
    if (s.blockAds)
      {'type': 'field', 'domain': ['geosite:category-ads-all'], 'outboundTag': 'block'},
    {'type': 'field', 'ip': ['geoip:private'], 'outboundTag': 'direct'},
    if (s.bypassIran) ...[
      {'type': 'field', 'domain': ['geosite:category-ir'], 'outboundTag': 'direct'},
      {'type': 'field', 'ip': ['geoip:ir'], 'outboundTag': 'direct'},
    ],
    if (winInclude) {'type': 'field', 'process': names, 'outboundTag': 'proxy'},
    if (winInclude) {'type': 'field', 'network': 'tcp,udp', 'outboundTag': 'direct'},
  ];

  // Smart mode: the best servers run side by side; Xray probes them and always uses the fastest one,
  // so a slow or dead server is replaced without any reconnect.
  final smartPool = pool.where((p) => p['_extra'] == null).toList();
  final useSmart = smartPool.isNotEmpty && extra == null;
  if (useSmart) {
    var k = 0;
    for (final p in smartPool) {
      final sub = jsonDecode(buildConfig(p, s)) as Map;
      for (final o in (sub['outbounds'] as List)) {
        final m = Map<String, dynamic>.from(o as Map);
        if (m['tag'] == 'proxy') {
          k++;
          m['tag'] = 'proxy-$k';
          outbounds.add(m);
        } else if (!outbounds.any((e) => e['tag'] == m['tag'])) {
          outbounds.add(m);
        }
      }
    }
    for (final r in rules) {
      if (r['outboundTag'] == 'proxy') {
        r.remove('outboundTag');
        r['balancerTag'] = 'smart';
      }
    }
    if (!winInclude) rules.add({'type': 'field', 'network': 'tcp,udp', 'balancerTag': 'smart'});
  }

  final cfg = {
    'log': {'loglevel': 'warning'},
    'dns': {'servers': dnsList(s), 'queryStrategy': s.ipv6 ? 'UseIP' : 'UseIPv4'},
    if (win) ...{
      'stats': {},
      'api': {'tag': 'api', 'services': ['StatsService']},
    },
    'inbounds': win
        ? [
            {
              'tag': 'socks-in',
              'listen': '127.0.0.1',
              'port': 10808,
              'protocol': 'socks',
              'settings': {'udp': true, 'auth': 'noauth'},
              'sniffing': {
                'enabled': true,
                'destOverride': ['http', 'tls']
              }
            },
            {
              'tag': 'http-in',
              'listen': '127.0.0.1',
              'port': 10809,
              'protocol': 'http',
              'settings': {},
              'sniffing': {
                'enabled': true,
                'destOverride': ['http', 'tls']
              }
            },
            {
              'tag': 'api',
              'listen': '127.0.0.1',
              'port': 10085,
              'protocol': 'dokodemo-door',
              'settings': {'address': '127.0.0.1'}
            },
          ]
        : [
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
    // the default per-connection buffer on ARM phones is tiny (4 kB); a bigger one raises throughput
    'policy': {
      'levels': {
        '0': {'bufferSize': 512}
      },
      if (win) 'system': {'statsOutboundUplink': true, 'statsOutboundDownlink': true},
    },
    // AsIs avoids extra DNS lookups when no geoip rules are in use.
    'routing': {'domainStrategy': s.bypassIran ? 'IPIfNonMatch' : 'AsIs', 'rules': rules},
  };
  if (useSmart) {
    (cfg['routing'] as Map)['balancers'] = [
      {
        'tag': 'smart',
        'selector': ['proxy'],
        'strategy': {'type': 'leastPing'},
        'fallbackTag': 'proxy',
      }
    ];
    cfg['observatory'] = {
      'subjectSelector': ['proxy'],
      'probeUrl': s.testUrl,
      'probeInterval': '30s',
      'enableConcurrency': true,
    };
  }
  return jsonEncode(cfg);
}
