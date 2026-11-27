import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:http/http.dart' as http;

import 'core.dart' show AppInfo;
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
  static String get _home => Platform.environment['HOME'] ?? Directory.systemTemp.path;
  static String get _macRes => '${File(Platform.resolvedExecutable).parent.parent.path}/Resources/xray';
  static String get xrayDir => Platform.isMacOS ? _macRes : '$appDir\\xray';
  static String get xrayExe {
    if (!Platform.isMacOS) return '$xrayDir\\xray.exe';
    final arch = (Process.runSync('uname', ['-m']).stdout as String).trim();
    return '$xrayDir/xray-${arch == 'arm64' ? 'arm64' : 'x64'}';
  }

  static String get dataDir {
    final base = Platform.isMacOS ? '$_home/Library/Application Support' : (Platform.environment['APPDATA'] ?? Directory.systemTemp.path);
    final d = Directory('$base${Platform.pathSeparator}DastRasNG');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d.path;
  }

  static String get logPath => '$dataDir${Platform.pathSeparator}xray.log';
  static String get _backupPath => '$dataDir${Platform.pathSeparator}proxy_backup.json';

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
      if (Platform.isMacOS) {
        await Process.run('chmod', ['+x', xrayExe]);
        await Process.run('xattr', ['-dr', 'com.apple.quarantine', xrayDir]);
      }
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
    final f = File('$dataDir${Platform.pathSeparator}run.json');
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
    if (Platform.isMacOS) {
      try {
        await Process.run('pkill', ['-f', xrayExe]);
      } catch (_) {}
      return;
    }
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
          if (n.startsWith('outbound>>>proxy') && n.endsWith('>>>traffic>>>downlink')) d += v;
          if (n.startsWith('outbound>>>proxy') && n.endsWith('>>>traffic>>>uplink')) u += v;
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
    if (Platform.isMacOS) return _macProxy(on);
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

  // ---------- program list for the per-app choice ----------

  /// Running programs. [AppInfo.system] is true for background processes (no window).
  static Future<List<AppInfo>> listApps() async {
    if (Platform.isMacOS) {
      try {
        final r = await Process.run('osascript', ['-e', 'tell application "System Events" to get name of (every process whose background only is false)']);
        final names = (r.stdout as String).split(',').map((e) => e.trim()).where((e) => e.isNotEmpty && e != 'DastRas NG').toSet().toList()..sort();
        return [for (final n in names) AppInfo(n, n, Uint8List(0), false)];
      } catch (_) {
        return [];
      }
    }
    try {
      Future<String> ps(String cmd) async {
        final r = await Process.run('powershell', ['-NoProfile', '-Command', '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $cmd'],
            stdoutEncoding: utf8);
        return r.stdout as String;
      }

      final win = await ps(r"Get-Process | Where-Object { $_.MainWindowHandle -ne 0 } | ForEach-Object { $_.ProcessName + '|' + $_.MainWindowTitle }");
      final all = await ps(r'Get-Process | Select-Object -ExpandProperty ProcessName -Unique');
      final titles = <String, String>{};
      for (final l in win.split(RegExp(r'[\r\n]+'))) {
        final p = l.split('|');
        if (p.isNotEmpty && p.first.trim().isNotEmpty) titles.putIfAbsent(p.first.trim(), () => p.length > 1 ? p.sublist(1).join('|').trim() : '');
      }
      final names = <String>{...titles.keys, ...all.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.isNotEmpty)};
      names.removeWhere((n) => n.toLowerCase() == 'dastras-ng' || n.toLowerCase() == 'xray');
      final out = <AppInfo>[];
      for (final n in names) {
        final t = titles[n] ?? '';
        out.add(AppInfo(n, t.isEmpty ? n : '$t ($n)', Uint8List(0), !titles.containsKey(n)));
      }
      out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------- extras ----------

  static Future<void> setAutostart(bool on) async {
    if (Platform.isMacOS) {
      final f = File('$_home/Library/LaunchAgents/com.dastras.ng.plist');
      try {
        if (on) {
          f.parent.createSync(recursive: true);
          f.writeAsStringSync('<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>Label</key><string>com.dastras.ng</string><key>ProgramArguments</key><array><string>${Platform.resolvedExecutable}</string><string>--minimized</string></array><key>RunAtLoad</key><true/></dict></plist>\n');
        } else if (f.existsSync()) {
          f.deleteSync();
        }
      } catch (_) {}
      return;
    }
    try {
      if (on) {
        await Process.run('reg', ['add', _runKey, '/v', 'DastRasNG', '/t', 'REG_SZ', '/d', '"${Platform.resolvedExecutable}" --minimized', '/f']);
      } else {
        await Process.run('reg', ['delete', _runKey, '/v', 'DastRasNG', '/f']);
      }
    } catch (_) {}
  }

  static Future<void> openLogs() async {
    try {
      await Process.run(Platform.isMacOS ? 'open' : 'explorer', [dataDir]);
    } catch (_) {}
  }

  /// Extracts the downloaded zip over the app folder after the app has closed, then restarts it.
  static Future<String> applyUpdate(String zipPath) async {
    if (Platform.isMacOS) {
      try {
        await Process.run('open', [zipPath]); // opens the disk image; the user drags the app into Applications
        return 'mac';
      } catch (e) {
        return 'error:$e';
      }
    }
    try {
      final tmp = '$dataDir${Platform.pathSeparator}update';
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
      final cmd = File('$dataDir${Platform.pathSeparator}update.cmd');
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

  // ---------- macOS system proxy (networksetup), backed up and restored ----------

  static String _shq(String s) => "'${s.replaceAll("'", "'\\''")}'";

  static Future<List<String>> _macServices() async {
    final r = await Process.run('networksetup', ['-listallnetworkservices']);
    return (r.stdout as String).split('\n').skip(1).map((e) => e.trim()).where((e) => e.isNotEmpty && !e.startsWith('*')).toList();
  }

  static Future<List<String>> _macGet(String svc, String kind) async {
    final r = await Process.run('networksetup', ['-get$kind', svc]);
    final m = <String, String>{};
    for (final l in (r.stdout as String).split('\n')) {
      final i = l.indexOf(':');
      if (i > 0) m[l.substring(0, i).trim()] = l.substring(i + 1).trim();
    }
    return [(m['Enabled'] ?? 'No'), (m['Server'] ?? ''), (m['Port'] ?? '0')];
  }

  /// Runs the commands directly; if macOS asks for administrator rights, runs them all with ONE password prompt.
  static Future<void> _macBatch(List<List<String>> cmds) async {
    var ok = true;
    for (final c in cmds) {
      final r = await Process.run('networksetup', c);
      if (r.exitCode != 0) {
        ok = false;
        break;
      }
    }
    if (ok) return;
    final sh = cmds.map((c) => 'networksetup ${c.map(_shq).join(' ')}').join('; ');
    final esc = sh.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    await Process.run('osascript', ['-e', 'do shell script "$esc" with administrator privileges']);
  }

  static Future<void> _macProxy(bool on) async {
    try {
      final svcs = await _macServices();
      const kinds = ['webproxy', 'securewebproxy', 'socksfirewallproxy'];
      if (on) {
        final f = File(_backupPath);
        if (!f.existsSync()) {
          final b = <String, dynamic>{};
          for (final s in svcs) {
            b[s] = {for (final k in kinds) k: await _macGet(s, k)};
          }
          f.writeAsStringSync(jsonEncode(b));
        }
        final cmds = <List<String>>[];
        for (final s in svcs) {
          cmds.add(['-setwebproxy', s, '127.0.0.1', '$httpPort']);
          cmds.add(['-setsecurewebproxy', s, '127.0.0.1', '$httpPort']);
          cmds.add(['-setsocksfirewallproxy', s, '127.0.0.1', '$socksPort']);
        }
        await _macBatch(cmds);
      } else {
        final f = File(_backupPath);
        var b = <String, dynamic>{};
        if (f.existsSync()) {
          try {
            b = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
          } catch (_) {}
        }
        final cmds = <List<String>>[];
        for (final s in svcs) {
          final prev = b[s] is Map ? Map<String, dynamic>.from(b[s] as Map) : <String, dynamic>{};
          for (final k in kinds) {
            final p = prev[k] is List ? List<String>.from((prev[k] as List).map((e) => '$e')) : const ['No', '', '0'];
            if (p[0].toLowerCase() == 'yes' && p[1].isNotEmpty && p[2] != '0') {
              cmds.add(['-set$k', s, p[1], p[2]]);
            } else {
              cmds.add(['-set${k}state', s, 'off']);
            }
          }
        }
        await _macBatch(cmds);
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
  }

  // ---------- speed meter: works with or without the VPN ----------

  static int? _widgetPid;

  static const String _widgetScript = r'''param([int]$ParentPid = 0, [string]$Unit = 'bytes', [string]$PosFile = '')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
$C = [System.Drawing.Color]

# ---------- helpers ----------
function Short([double]$bps) {
  if ($Unit -eq 'bits') { $v = $bps * 8; $s = 'b'; $k = 1000.0 } else { $v = $bps; $s = ''; $k = 1024.0 }
  if ($v -ge ($k * $k * $k)) { return ('{0:N2}G{1}' -f ($v / ($k * $k * $k)), $s) }
  if ($v -ge ($k * $k)) { return ('{0:N2}M{1}' -f ($v / ($k * $k)), $s) }
  if ($v -ge $k) { return ('{0:N1}K{1}' -f ($v / $k), $s) }
  return ('{0:N0}{1}' -f $v, $s)
}

function Sizes([double]$b) {
  if ($b -ge 1073741824) { return ('{0:N2} GB' -f ($b / 1073741824)) }
  if ($b -ge 1048576) { return ('{0:N1} MB' -f ($b / 1048576)) }
  return ('{0:N0} KB' -f ($b / 1024))
}

function Totals {
  $rx = [int64]0
  $tx = [int64]0
  foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($n.OperationalStatus -ne 'Up') { continue }
    if ($n.NetworkInterfaceType -eq 'Loopback' -or $n.NetworkInterfaceType -eq 'Tunnel') { continue }
    if ($n.Description -match 'TAP-|Wintun|\bTUN\b|VPN|Virtual|vEthernet|VMware|VirtualBox|Hyper-V|Npcap|Bluetooth') { continue }
    $s = $n.GetIPv4Statistics()
    $rx += $s.BytesReceived
    $tx += $s.BytesSent
  }
  return @($rx, $tx)
}

function RoundRect($r, [int]$d) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $p.AddArc($r.X, $r.Y, $d, $d, 180, 90)
  $p.AddArc($r.Right - $d, $r.Y, $d, $d, 270, 90)
  $p.AddArc($r.Right - $d, $r.Bottom - $d, $d, $d, 0, 90)
  $p.AddArc($r.X, $r.Bottom - $d, $d, $d, 90, 90)
  $p.CloseFigure()
  return $p
}

# ---------- state ----------
$script:dn = 0.0
$script:upv = 0.0
$script:pkD = 1.0
$script:pkU = 1.0
$script:ping = '--'
$script:conns = 0
$script:pHosts = @('1.1.1.1', '8.8.8.8', '9.9.9.9')
$script:pIdx = 0
$script:pc = $null
$script:pAr = $null
$script:pSw = $null

function PingStart {
  try {
    $script:pc = New-Object System.Net.Sockets.TcpClient
    $script:pSw = [System.Diagnostics.Stopwatch]::StartNew()
    $script:pAr = $script:pc.BeginConnect($script:pHosts[$script:pIdx], 443, $null, $null)
  } catch { $script:pc = $null; $script:pAr = $null }
}

function PingPoll {
  if ($null -eq $script:pAr) { return }
  if ($script:pAr.IsCompleted) {
    $ms = [int]$script:pSw.ElapsedMilliseconds
    $ok = $false
    try { $script:pc.EndConnect($script:pAr); $ok = $true } catch {}
    try { $script:pc.Close() } catch {}
    $script:pAr = $null
    $script:pc = $null
    if ($ok) { $script:ping = ('{0}ms' -f $ms) } else { $script:ping = '--'; $script:pIdx = ($script:pIdx + 1) % $script:pHosts.Count }
  } elseif ($script:pSw.ElapsedMilliseconds -gt 1500) {
    try { $script:pc.Close() } catch {}
    $script:pAr = $null
    $script:pc = $null
    $script:ping = '--'
    $script:pIdx = ($script:pIdx + 1) % $script:pHosts.Count
  }
}

# ---------- window: small glass panel ----------
$W = 184
$H = 80
$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = 'None'
$f.TopMost = $true
$f.ShowInTaskbar = $false
$f.StartPosition = 'Manual'
$f.ClientSize = New-Object System.Drawing.Size($W, $H)
$f.BackColor = $C::FromArgb(14, 20, 46)
$f.Opacity = 0.93
$f.Region = New-Object System.Drawing.Region((RoundRect (New-Object System.Drawing.Rectangle(0, 0, $W, $H)) 12))
try { $f.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($f, $true, $null) } catch {}

$fontB = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
$white = New-Object System.Drawing.SolidBrush($C::FromArgb(240, 245, 255))
$sfRight = New-Object System.Drawing.StringFormat
$sfRight.Alignment = [System.Drawing.StringAlignment]::Far

$f.Add_Paint({
  $g = $_.Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
  $full = New-Object System.Drawing.Rectangle(0, 0, ($W - 1), ($H - 1))
  $path = RoundRect $full 12
  # deep blue glass body
  $bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush($full, $C::FromArgb(255, 36, 56, 108), $C::FromArgb(255, 9, 14, 36), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
  $g.FillPath($bg, $path)
  # light reflection on the upper part
  $top = New-Object System.Drawing.Rectangle(0, 0, $W, 34)
  $hl = New-Object System.Drawing.Drawing2D.LinearGradientBrush($top, $C::FromArgb(70, 255, 255, 255), $C::FromArgb(6, 255, 255, 255), [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
  $g.SetClip($path)
  $g.FillRectangle($hl, $top)
  $g.ResetClip()
  $pen = New-Object System.Drawing.Pen($C::FromArgb(210, 120, 150, 220), 1)
  $g.DrawPath($pen, $path)

  # row 1: arrows, ping, connections
  $o = New-Object System.Drawing.SolidBrush($C::FromArgb(255, 255, 150, 50))
  $gr = New-Object System.Drawing.SolidBrush($C::FromArgb(255, 70, 220, 110))
  $g.FillPolygon($o, @((New-Object System.Drawing.Point(11, 6)), (New-Object System.Drawing.Point(15, 12)), (New-Object System.Drawing.Point(12, 12)), (New-Object System.Drawing.Point(12, 20)), (New-Object System.Drawing.Point(10, 20)), (New-Object System.Drawing.Point(10, 12)), (New-Object System.Drawing.Point(7, 12))))
  $g.FillPolygon($gr, @((New-Object System.Drawing.Point(20, 21)), (New-Object System.Drawing.Point(24, 15)), (New-Object System.Drawing.Point(21, 15)), (New-Object System.Drawing.Point(21, 7)), (New-Object System.Drawing.Point(19, 7)), (New-Object System.Drawing.Point(19, 15)), (New-Object System.Drawing.Point(16, 15))))
  $g.DrawString($script:ping, $fontB, $white, 30, 4)
  $blue = New-Object System.Drawing.SolidBrush($C::FromArgb(255, 80, 140, 255))
  $g.FillRectangle($blue, 132, 10, 7, 7)
  $g.DrawString([string]$script:conns, $fontB, $white, (New-Object System.Drawing.RectangleF(138, 4, 40, 18)), $sfRight)

  # rows 2 and 3: bars (bright = now, dark = recent peak) and the numbers
  $scaleD = [Math]::Max($script:pkD, 262144.0)
  $scaleU = [Math]::Max($script:pkU, 131072.0)
  $rows = @(
    @(33, $script:dn, $script:pkD, $scaleD, $C::FromArgb(255, 255, 160, 70), $C::FromArgb(255, 255, 110, 30), $C::FromArgb(255, 120, 55, 45)),
    @(55, $script:upv, $script:pkU, $scaleU, $C::FromArgb(255, 90, 235, 130), $C::FromArgb(255, 40, 170, 85), $C::FromArgb(255, 30, 95, 62))
  )
  foreach ($r in $rows) {
    $y = [int]$r[0]
    $bx = 24
    $bw = 106
    $track = New-Object System.Drawing.SolidBrush($C::FromArgb(70, 255, 255, 255))
    $g.FillPath($track, (RoundRect (New-Object System.Drawing.Rectangle($bx, $y, $bw, 12)) 5))
    $pw = [int]([Math]::Min(1.0, $r[2] / $r[3]) * $bw)
    $cw = [int]([Math]::Min(1.0, $r[1] / $r[3]) * $bw)
    if ($pw -gt 6) {
      $g.FillPath((New-Object System.Drawing.SolidBrush($r[6])), (RoundRect (New-Object System.Drawing.Rectangle($bx, $y, $pw, 12)) 5))
    }
    if ($cw -gt 6) {
      $rc = New-Object System.Drawing.Rectangle($bx, $y, $cw, 12)
      $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rc, $r[4], $r[5], [System.Drawing.Drawing2D.LinearGradientMode]::Vertical)
      $g.FillPath($gb, (RoundRect $rc 5))
    }
    $sq = New-Object System.Drawing.SolidBrush($r[5])
    $g.FillRectangle($sq, 9, ($y + 2), 8, 8)
    $g.DrawString((Short $r[1]), $fontB, $white, (New-Object System.Drawing.RectangleF(130, ($y - 4), 50, 18)), $sfRight)
  }
})

# ---------- position: remembered, otherwise bottom-right just above the clock ----------
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$x = $wa.Right - $W - 8
$y = $wa.Bottom - $H - 8
if ($PosFile -ne '' -and (Test-Path $PosFile)) {
  try {
    $p = (Get-Content $PosFile -Raw).Trim().Split(',')
    $px = [int]$p[0]
    $py = [int]$p[1]
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    if ($px -ge $vs.Left -and $px -le ($vs.Right - 40) -and $py -ge $vs.Top -and $py -le ($vs.Bottom - 30)) { $x = $px; $y = $py }
  } catch {}
}
$f.Location = New-Object System.Drawing.Point($x, $y)

# ---------- drag with the left mouse button ----------
$script:drag = $false
$f.Add_MouseDown({
  if ($_.Button -eq 'Left') {
    $script:drag = $true
    $script:c0 = [System.Windows.Forms.Cursor]::Position
    $script:l0 = $f.Location
  }
})
$f.Add_MouseMove({
  if ($script:drag) {
    $c = [System.Windows.Forms.Cursor]::Position
    $f.Location = New-Object System.Drawing.Point(($script:l0.X + $c.X - $script:c0.X), ($script:l0.Y + $c.Y - $script:c0.Y))
  }
})
$f.Add_MouseUp({
  if ($script:drag) {
    $script:drag = $false
    if ($PosFile -ne '') { try { Set-Content -Path $PosFile -Value ('{0},{1}' -f $f.Location.X, $f.Location.Y) } catch {} }
  }
})

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$item = $menu.Items.Add('Close')
$item.Add_Click({ $f.Close() })
$f.ContextMenuStrip = $menu
$tt = New-Object System.Windows.Forms.ToolTip

# ---------- live data ----------
$tot0 = Totals
$script:last = $tot0
$script:sw = [System.Diagnostics.Stopwatch]::StartNew()
$script:tick = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
  $script:tick++
  if ($ParentPid -gt 0 -and ($script:tick % 10) -eq 0) {
    if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { $f.Close(); return }
  }
  $now = Totals
  $dt = $script:sw.Elapsed.TotalSeconds
  $script:sw.Restart()
  if ($dt -gt 0) {
    $dr = ($now[0] - $script:last[0]) / $dt
    $du = ($now[1] - $script:last[1]) / $dt
    if ($dr -lt 0) { $dr = 0 }
    if ($du -lt 0) { $du = 0 }
    $script:dn = 0.5 * $script:dn + 0.5 * $dr
    $script:upv = 0.5 * $script:upv + 0.5 * $du
    $script:pkD = [Math]::Max($script:pkD * 0.992, $script:dn)
    $script:pkU = [Math]::Max($script:pkU * 0.992, $script:upv)
  }
  $script:last = $now
  PingPoll
  if (($script:tick % 6) -eq 1 -and $null -eq $script:pAr) { PingStart }
  if (($script:tick % 6) -eq 3) {
    try { $script:conns = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpConnections().Count } catch {}
  }
  if (($script:tick % 4) -eq 0) {
    $tt.SetToolTip($f, ('Down {0}   Up {1}   (since start)' -f (Sizes ($now[0] - $tot0[0])), (Sizes ($now[1] - $tot0[1]))))
  }
  $f.Invalidate()
})
$timer.Start()
[System.Windows.Forms.Application]::Run($f)
''';

  /// Floating always-on-top speed meter (Windows). Shows the real speed of the network cards.
  static Future<void> startWidget({bool bits = false}) async {
    if (!Platform.isWindows) return;
    await stopWidget();
    try {
      final script = File('$dataDir${Platform.pathSeparator}speed_widget.ps1');
      // a BOM lets Windows PowerShell read the non-ASCII characters correctly
      script.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(_widgetScript)]);
      final p = await Process.start(
        'powershell',
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script.path,
          '-ParentPid',
          '$pid',
          '-Unit',
          bits ? 'bits' : 'bytes',
          '-PosFile',
          '$dataDir${Platform.pathSeparator}widget_pos.txt',
        ],
        mode: ProcessStartMode.detached,
      );
      _widgetPid = p.pid;
    } catch (_) {}
  }

  static Future<void> stopWidget() async {
    final p = _widgetPid;
    _widgetPid = null;
    if (p != null) {
      try {
        Process.killPid(p);
      } catch (_) {}
    }
  }

  /// Total bytes received / sent by the machine (all real network cards), or null if unknown.
  static Future<(int, int)?> netTotals() async {
    try {
      if (Platform.isWindows) {
        final r = await Process.run('netstat', ['-e']);
        final m = RegExp(r'^\s*\S+\s+(\d+)\s+(\d+)\s*$', multiLine: true).firstMatch(r.stdout as String);
        if (m == null) return null;
        return (int.parse(m.group(1)!), int.parse(m.group(2)!));
      }
      if (Platform.isMacOS) {
        final r = await Process.run('netstat', ['-ib']);
        var rx = 0, tx = 0;
        for (final line in (r.stdout as String).split('\n')) {
          final t = line.trim().split(RegExp(r'\s+'));
          if (t.length < 10 || !t[2].startsWith('<Link#')) continue;
          final name = t[0];
          if (name.startsWith('lo') || name.startsWith('utun') || name.startsWith('bridge') || name.startsWith('awdl') || name.startsWith('llw') || name.startsWith('gif') || name.startsWith('stf') || name.startsWith('ap')) continue;
          final ib = int.tryParse(t[t.length - 5]);
          final ob = int.tryParse(t[t.length - 2]);
          if (ib != null && ob != null) {
            rx += ib;
            tx += ob;
          }
        }
        return (rx, tx);
      }
    } catch (_) {}
    return null;
  }
}
