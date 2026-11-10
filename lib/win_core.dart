import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'service.dart' show tcpStat;
import 'share_links.dart';

/// Windows engine: runs xray.exe as a local proxy and manages the system proxy safely.
///
/// Safety rules that avoid the usual "no internet after closing the VPN" problems:
///  * the previous proxy settings are backed up and restored (even after a crash),
///  * only our own xray.exe is ever killed, never other programs',
///  * ports are chosen free, so another client can not block us,
///  * a health check restarts the core when the connection silently dies.
class WinCore {
  static String state = 'stopped'; // stopped | starting | running | error:<msg>
  static int down = 0, up = 0, totDown = 0, totUp = 0;
  static int socksPort = 10808, httpPort = 10809, apiPort = 10085;

  /// Called when restarting the core did not help; the UI may switch to another server.
  static void Function()? onUnhealthy;

  static Process? _proc;
  static Timer? _statsTimer, _healthTimer;
  static String? _lastConfig;
  static int _fails = 0, _restarts = 0, _lastDown = 0, _lastUp = 0;
  static bool _firstStat = true;

  static const _inet = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const _runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';

  // ---------- paths ----------
  static String get appDir => File(Platform.resolvedExecutable).parent.path;
  static String get xrayDir => '$appDir\\xray';
  static String get xrayExe => '$xrayDir\\xray.exe';

  static String get dataDir {
    final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    final d = Directory('$base\\DastRasNG');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  static String get logPath => '$dataDir\\xray.log';
  static String get _backupPath => '$dataDir\\proxy_backup.json';

  // ---------- bridge used by Core ----------

  static Future<Map<String, dynamic>> invoke(String method, Map<String, dynamic> payload) async {
    if (method == 'convertShareLinksToXrayJson') {
      final obs = parseShareText((payload['text'] ?? '').toString());
      if (obs.isEmpty) return {'success': false, 'error': 'no usable config'};
      return {
        'success': true,
        'data': {'outbounds': obs},
      };
    }
    if (method == 'pingBatch') {
      final out = <Map<String, dynamic>>[];
      for (final c in (payload['configs'] as List)) {
        try {
          final j = jsonDecode((c as Map)['xrayJson'] as String) as Map;
          final ob = Map<String, dynamic>.from((j['outbounds'] as List).first as Map);
          final st = await tcpStat(Node(ob, 'x'), 2);
          out.add({'delay': (st != null && st.ok > 0) ? st.min : 99999});
        } catch (_) {
          out.add({'delay': 99999});
        }
      }
      return {'success': true, 'data': out};
    }
    return {'success': false, 'error': 'unsupported on Windows'};
  }

  static Future<String?> announce(List<String> urls) async {
    for (final u in urls) {
      try {
        final r = await http.get(Uri.parse(u), headers: {'User-Agent': 'DastRasNG'}).timeout(const Duration(seconds: 8));
        if (r.statusCode == 200 && jsonDecode(r.body) is List) return r.body;
      } catch (_) {}
    }
    return null;
  }

  // ---------- start / stop ----------

  static Future<String> start(String config) async {
    await stop();
    state = 'starting';
    if (!File(xrayExe).existsSync()) {
      state = 'error:xray.exe not found next to the app';
      return 'error';
    }
    try {
      await _killStale();
      final cfg = jsonDecode(config) as Map<String, dynamic>;
      socksPort = await _freePort(10808);
      httpPort = await _freePort(socksPort + 1);
      apiPort = await _freePort(10085);
      for (final ib in (cfg['inbounds'] as List)) {
        final m = ib as Map;
        if (m['tag'] == 'socks-in') m['port'] = socksPort;
        if (m['tag'] == 'http-in') m['port'] = httpPort;
        if (m['tag'] == 'api') m['port'] = apiPort;
      }
      cfg['log'] = {'loglevel': 'warning', 'access': 'none', 'error': logPath};
      _lastConfig = jsonEncode(cfg);
      if (!await _launch(_lastConfig!)) return 'error';
      await _setProxy(true);
      state = 'running';
      _fails = 0;
      _restarts = 0;
      _startStats();
      _startHealth();
      return 'ok';
    } catch (e) {
      state = 'error:$e';
      await stop(keepState: true);
      return 'error';
    }
  }

  static Future<void> stop({bool keepState = false}) async {
    _statsTimer?.cancel();
    _statsTimer = null;
    _healthTimer?.cancel();
    _healthTimer = null;
    final p = _proc;
    _proc = null;
    if (p != null || File(_backupPath).existsSync()) await _setProxy(false);
    p?.kill();
    down = up = totDown = totUp = 0;
    if (!keepState) state = 'stopped';
  }

  /// Runs once when the app opens: undoes whatever a crashed session left behind.
  static Future<void> cleanupStale() async {
    try {
      await _killStale();
      if (File(_backupPath).existsSync()) await _setProxy(false);
    } catch (_) {}
  }

  static Future<bool> _launch(String configJson) async {
    final f = File('$dataDir\\run.json');
    await f.writeAsString(configJson);
    final p = await Process.start(
      xrayExe,
      ['run', '-config', f.path],
      workingDirectory: xrayDir,
      environment: {'XRAY_LOCATION_ASSET': xrayDir},
    );
    _proc = p;
    final buf = StringBuffer();
    void collect(String s) {
      if (buf.length < 1500) buf.write(s);
    }

    p.stdout.transform(utf8.decoder).listen(collect, onError: (_) {});
    p.stderr.transform(utf8.decoder).listen(collect, onError: (_) {});
    var exited = false;
    unawaited(p.exitCode.then((_) {
      exited = true;
      if (identical(_proc, p)) {
        _proc = null;
        if (state == 'running') {
          // the core died on its own: try to bring it back
          if (_restarts < 3) {
            _restarts++;
            unawaited(_restart());
          } else {
            state = 'error:xray stopped unexpectedly';
            unawaited(_setProxy(false));
          }
        }
      }
    }));

    // wait until the local proxy accepts connections (instead of guessing a delay)
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    var ok = false;
    while (DateTime.now().isBefore(deadline) && !exited) {
      try {
        final s = await Socket.connect(InternetAddress.loopbackIPv4, httpPort, timeout: const Duration(milliseconds: 300));
        s.destroy();
        ok = true;
        break;
      } catch (_) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    try {
      await f.delete(); // it holds credentials and is not needed after startup
    } catch (_) {}
    if (!ok) {
      final msg = buf.toString().trim();
      state = 'error:${msg.isEmpty ? 'xray did not start' : msg}';
      await stop(keepState: true);
      return false;
    }
    return true;
  }

  static Future<void> _restart() async {
    final p = _proc;
    _proc = null;
    p?.kill();
    await Future.delayed(const Duration(milliseconds: 600));
    final c = _lastConfig;
    if (c == null || state != 'running') return;
    if (!await _launch(c)) await _setProxy(false);
  }

  static Future<int> _freePort(int preferred) async {
    for (var p = preferred; p < preferred + 50; p++) {
      try {
        final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, p);
        await s.close();
        return p;
      } catch (_) {}
    }
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  /// Ends only OUR xray.exe left over from a crash (never another program's).
  static Future<void> _killStale() async {
    try {
      final exe = xrayExe.replaceAll("'", "''");
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Get-CimInstance Win32_Process -Filter \"Name='xray.exe'\" | "
            "Where-Object { \$_.ExecutablePath -eq '$exe' } | "
            "ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }",
      ]);
    } catch (_) {}
  }

  // ---------- health check ----------

  static void _startHealth() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      if (state != 'running') return;
      if (await _probe()) {
        _fails = 0;
        _restarts = 0;
        return;
      }
      _fails++;
      if (_fails >= 3) {
        _fails = 0;
        if (_restarts < 2) {
          _restarts++;
          await _restart();
        } else {
          _restarts = 0;
          onUnhealthy?.call();
        }
      }
    });
  }

  static Future<bool> _probe() async {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 6)
      ..findProxy = (u) => 'PROXY 127.0.0.1:$httpPort';
    try {
      final req = await c.getUrl(Uri.parse('http://www.gstatic.com/generate_204'));
      final r = await req.close().timeout(const Duration(seconds: 8));
      await r.drain();
      return r.statusCode == 204 || r.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  // ---------- live traffic ----------

  static void _startStats() {
    _firstStat = true;
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (state != 'running') return;
      try {
        final r = await Process.run(xrayExe, ['api', 'statsquery', '-s', '127.0.0.1:$apiPort'],
            environment: {'XRAY_LOCATION_ASSET': xrayDir});
        if (r.exitCode != 0) return;
        final j = jsonDecode(r.stdout as String) as Map;
        var d = 0, u = 0;
        for (final e in (j['stat'] as List? ?? const [])) {
          final n = '${(e as Map)['name']}';
          final v = int.tryParse('${e['value']}') ?? 0;
          if (n == 'outbound>>>proxy>>>traffic>>>downlink') d = v;
          if (n == 'outbound>>>proxy>>>traffic>>>uplink') u = v;
        }
        if (_firstStat) {
          _lastDown = d;
          _lastUp = u;
          _firstStat = false;
        }
        down = (d - _lastDown).clamp(0, 1 << 40);
        up = (u - _lastUp).clamp(0, 1 << 40);
        _lastDown = d;
        _lastUp = u;
        totDown = d;
        totUp = u;
      } catch (_) {}
    });
  }

  // ---------- Windows system proxy (backed up and restored) ----------

  static Future<String?> _regGet(String name) async {
    try {
      final r = await Process.run('reg', ['query', _inet, '/v', name]);
      if (r.exitCode != 0) return null;
      final m = RegExp('$name\\s+REG_\\w+\\s+(.*)', caseSensitive: false).firstMatch(r.stdout as String);
      return m?.group(1)?.trim();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _regSet(String name, String type, String value) =>
      Process.run('reg', ['add', _inet, '/v', name, '/t', type, '/d', value, '/f']);

  static Future<void> _regDel(String name) => Process.run('reg', ['delete', _inet, '/v', name, '/f']);

  static Future<void> _setProxy(bool on) async {
    try {
      if (on) {
        final f = File(_backupPath);
        if (!f.existsSync()) {
          // keep the FIRST backup: after a crash it still holds the user's real settings
          f.writeAsStringSync(jsonEncode({
            'enable': await _regGet('ProxyEnable'),
            'server': await _regGet('ProxyServer'),
            'override': await _regGet('ProxyOverride'),
            'pac': await _regGet('AutoConfigURL'),
          }));
        }
        await _regSet('ProxyEnable', 'REG_DWORD', '1');
        await _regSet('ProxyServer', 'REG_SZ', '127.0.0.1:$httpPort');
        await _regSet('ProxyOverride', 'REG_SZ', '<local>;localhost;127.*;10.*;172.16.*;192.168.*');
        await _regDel('AutoConfigURL'); // a PAC script would override our proxy
      } else {
        var b = <String, dynamic>{};
        final f = File(_backupPath);
        if (f.existsSync()) {
          try {
            b = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
          } catch (_) {}
        }
        final wasOn = '${b['enable']}'.toLowerCase() == '0x1';
        await _regSet('ProxyEnable', 'REG_DWORD', wasOn ? '1' : '0');
        if (b['server'] != null) {
          await _regSet('ProxyServer', 'REG_SZ', '${b['server']}');
        } else {
          await _regDel('ProxyServer');
        }
        if (b['override'] != null) {
          await _regSet('ProxyOverride', 'REG_SZ', '${b['override']}');
        } else {
          await _regDel('ProxyOverride');
        }
        if (b['pac'] != null) await _regSet('AutoConfigURL', 'REG_SZ', '${b['pac']}');
        if (f.existsSync()) f.deleteSync();
      }
      await _refreshInet();
    } catch (_) {}
  }

  /// Tells Windows and the running programs that the proxy settings changed.
  static Future<void> _refreshInet() async {
    try {
      await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        r'''$s='[DllImport("wininet.dll")] public static extern bool InternetSetOption(IntPtr h,int o,IntPtr b,int l);'; $t=Add-Type -MemberDefinition $s -Name W -Namespace N -PassThru; $t::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0) | Out-Null; $t::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0) | Out-Null''',
      ]);
    } catch (_) {}
  }

  // ---------- extras ----------

  static Future<void> setAutostart(bool on) async {
    try {
      if (on) {
        await Process.run('reg', ['add', _runKey, '/v', 'DastRasNG', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}"', '/f']);
      } else {
        await Process.run('reg', ['delete', _runKey, '/v', 'DastRasNG', '/f']);
      }
    } catch (_) {}
  }

  static Future<void> openLogs() async {
    try {
      await Process.run('explorer', [dataDir]);
    } catch (_) {}
  }

  /// Extracts the downloaded zip over the app folder after the app has closed, then restarts it.
  static Future<String> applyUpdate(String zipPath) async {
    try {
      final tmp = '$dataDir\\update';
      final dir = Directory(tmp);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        "Expand-Archive -LiteralPath '$zipPath' -DestinationPath '$tmp' -Force",
      ]);
      if (r.exitCode != 0) return 'error:could not extract the update';
      final subs = dir.listSync().whereType<Directory>().toList();
      final inner = subs.isNotEmpty ? subs.first.path : tmp;
      final exeName = File(Platform.resolvedExecutable).uri.pathSegments.last;
      final cmd = File('$dataDir\\update.cmd');
      cmd.writeAsStringSync('@echo off\r\n'
          'ping 127.0.0.1 -n 4 >nul\r\n'
          ':wait\r\n'
          'tasklist /fi "imagename eq $exeName" | find /i "$exeName" >nul && (ping 127.0.0.1 -n 2 >nul & goto wait)\r\n'
          'xcopy "$inner\\*" "$appDir\\" /e /y /q >nul\r\n'
          'start "" "${Platform.resolvedExecutable}"\r\n');
      await stop();
      await Process.start('cmd', ['/c', cmd.path], mode: ProcessStartMode.detached);
      exit(0);
    } catch (e) {
      return 'error:$e';
    }
  }
}
