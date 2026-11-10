import 'dart:convert';

/// Turns share links (vless / vmess / trojan / ss) or a whole subscription body into Xray outbounds.
/// Used on Windows, where the Android libXray converter is not available.
List<Map<String, dynamic>> parseShareText(String text) {
  var t = text.trim();
  if (!t.contains('://')) {
    final dec = _b64(t);
    if (dec != null && dec.contains('://')) t = dec;
  }
  final out = <Map<String, dynamic>>[];
  for (final raw in t.split(RegExp(r'[\r\n]+'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    try {
      Map<String, dynamic>? ob;
      if (line.startsWith('vless://')) {
        ob = _vless(line);
      } else if (line.startsWith('vmess://')) {
        ob = _vmess(line);
      } else if (line.startsWith('trojan://')) {
        ob = _trojan(line);
      } else if (line.startsWith('ss://')) {
        ob = _ss(line);
      }
      if (ob != null) out.add(ob);
    } catch (_) {}
  }
  return out;
}

String? _b64(String s) {
  try {
    var x = s.trim().replaceAll('-', '+').replaceAll('_', '/').replaceAll(RegExp(r'\s'), '');
    while (x.length % 4 != 0) {
      x += '=';
    }
    return utf8.decode(base64.decode(x), allowMalformed: true);
  } catch (_) {
    return null;
  }
}

String _dec(String s) {
  try {
    return Uri.decodeComponent(s);
  } catch (_) {
    return s;
  }
}

String _tag(Uri u, String host) => u.fragment.isEmpty ? host : _dec(u.fragment);

Map<String, dynamic> _stream(Map<String, String> q, String host, {String defaultSec = 'none'}) {
  var net = (q['type'] ?? 'tcp').toLowerCase();
  if (net == 'h2') net = 'http';
  if (net == 'splithttp') net = 'xhttp';
  final sec = (q['security'] ?? defaultSec).toLowerCase();
  final sni = (q['sni'] ?? q['peer'] ?? q['host'] ?? host);
  final hostHdr = q['host'] ?? '';
  final path = (q['path'] ?? '').isEmpty ? '/' : q['path']!;
  final s = <String, dynamic>{'network': net, 'security': sec};
  switch (net) {
    case 'ws':
      s['wsSettings'] = {
        'path': path,
        'headers': {'Host': hostHdr.isNotEmpty ? hostHdr : sni},
      };
      break;
    case 'grpc':
      s['grpcSettings'] = {'serviceName': q['serviceName'] ?? '', 'multiMode': (q['mode'] ?? '') == 'multi'};
      break;
    case 'httpupgrade':
      s['httpupgradeSettings'] = {'path': path, if (hostHdr.isNotEmpty) 'host': hostHdr};
      break;
    case 'xhttp':
      s['xhttpSettings'] = {'path': path, if (hostHdr.isNotEmpty) 'host': hostHdr, 'mode': q['mode'] ?? 'auto'};
      break;
    case 'http':
      s['httpSettings'] = {'path': path, 'host': hostHdr.isEmpty ? <String>[] : hostHdr.split(',')};
      break;
    default:
      if ((q['headerType'] ?? '') == 'http') {
        s['tcpSettings'] = {
          'header': {
            'type': 'http',
            'request': {
              'path': path.split(','),
              'headers': {'Host': hostHdr.split(',')},
            },
          },
        };
      }
  }
  if (sec == 'tls') {
    s['tlsSettings'] = {
      'serverName': sni,
      'fingerprint': q['fp'] ?? 'chrome',
      if ((q['alpn'] ?? '').isNotEmpty) 'alpn': q['alpn']!.split(','),
      'allowInsecure': false,
    };
  } else if (sec == 'reality') {
    s['realitySettings'] = {
      'serverName': sni,
      'fingerprint': q['fp'] ?? 'chrome',
      'publicKey': q['pbk'] ?? '',
      'shortId': q['sid'] ?? '',
      'spiderX': q['spx'] ?? '',
    };
  }
  return s;
}

Map<String, dynamic> _vless(String link) {
  final u = Uri.parse(link);
  final q = u.queryParameters;
  final host = u.host;
  return {
    'protocol': 'vless',
    'tag': _tag(u, host),
    'settings': {
      'vnext': [
        {
          'address': host,
          'port': u.port == 0 ? 443 : u.port,
          'users': [
            {
              'id': _dec(u.userInfo),
              'encryption': q['encryption'] ?? 'none',
              if ((q['flow'] ?? '').isNotEmpty) 'flow': q['flow'],
            }
          ],
        }
      ],
    },
    'streamSettings': _stream(q, host),
  };
}

Map<String, dynamic> _vmess(String link) {
  final j = jsonDecode(_b64(link.substring(8))!) as Map;
  final host = '${j['add']}';
  final q = <String, String>{};
  void put(String k, Object? v) {
    final s = '${v ?? ''}';
    if (s.isNotEmpty && s != 'null') q[k] = s;
  }

  put('type', j['net'] ?? 'tcp');
  put('host', j['host']);
  put('path', j['path']);
  put('sni', j['sni']);
  put('alpn', j['alpn']);
  put('fp', j['fp']);
  put('headerType', j['type']);
  put('serviceName', j['path']);
  q['security'] = '${j['tls'] ?? ''}' == 'tls' ? 'tls' : 'none';
  return {
    'protocol': 'vmess',
    'tag': '${j['ps'] ?? host}',
    'settings': {
      'vnext': [
        {
          'address': host,
          'port': int.parse('${j['port']}'),
          'users': [
            {'id': '${j['id']}', 'alterId': int.tryParse('${j['aid'] ?? 0}') ?? 0, 'security': '${j['scy'] ?? 'auto'}'}
          ],
        }
      ],
    },
    'streamSettings': _stream(q, host),
  };
}

Map<String, dynamic> _trojan(String link) {
  final u = Uri.parse(link);
  final host = u.host;
  return {
    'protocol': 'trojan',
    'tag': _tag(u, host),
    'settings': {
      'servers': [
        {'address': host, 'port': u.port == 0 ? 443 : u.port, 'password': _dec(u.userInfo)}
      ],
    },
    'streamSettings': _stream(u.queryParameters, host, defaultSec: 'tls'),
  };
}

Map<String, dynamic>? _ss(String link) {
  var body = link.substring(5);
  var name = '';
  final h = body.indexOf('#');
  if (h >= 0) {
    name = _dec(body.substring(h + 1));
    body = body.substring(0, h);
  }
  final qi = body.indexOf('?');
  if (qi >= 0) {
    if (body.substring(qi + 1).contains('plugin=')) return null; // plugins are not supported
    body = body.substring(0, qi);
  }
  var cred = '';
  var hp = '';
  final at = body.lastIndexOf('@');
  if (at >= 0) {
    cred = body.substring(0, at);
    hp = body.substring(at + 1);
    if (!cred.contains(':')) cred = _b64(cred) ?? cred;
  } else {
    final d = _b64(body);
    if (d == null) return null;
    final a2 = d.lastIndexOf('@');
    if (a2 < 0) return null;
    cred = d.substring(0, a2);
    hp = d.substring(a2 + 1);
  }
  final c = cred.indexOf(':');
  final p = hp.lastIndexOf(':');
  if (c < 0 || p < 0) return null;
  final host = hp.substring(0, p);
  return {
    'protocol': 'shadowsocks',
    'tag': name.isEmpty ? host : name,
    'settings': {
      'servers': [
        {
          'address': host,
          'port': int.parse(hp.substring(p + 1).replaceAll('/', '')),
          'method': _dec(cred.substring(0, c)),
          'password': _dec(cred.substring(c + 1)),
        }
      ],
    },
  };
}
