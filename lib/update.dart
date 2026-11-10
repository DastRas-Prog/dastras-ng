import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'core.dart';
import 'lang.dart';
import 'pal.dart';
import 'theme.dart';

/// Injected by the build (GitHub run number). 0 = local/dev build.
const int kBuild = int.fromEnvironment('BUILD_NUMBER', defaultValue: 0);
const String kVersion = '2.0.0';
const String kRepo = 'mojyrayzor-prog/dastras-ng';

class UpdateInfo {
  final int build;
  final String tag, notes, url;
  const UpdateInfo(this.build, this.tag, this.notes, this.url);
}

String _apkName(String abi) {
  if (abi == 'windows') return 'DastRas-NG-windows.zip';
  if (abi.contains('arm64')) return 'app-arm64-v8a-release.apk';
  if (abi.contains('armeabi') || abi.contains('v7')) return 'app-armeabi-v7a-release.apk';
  if (abi.contains('x86_64')) return 'app-x86_64-release.apk';
  return 'app-universal-release.apk';
}

int _buildOf(String tag) => int.tryParse(tag.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;

/// Reads the newest GitHub release. Returns null when offline / nothing found.
Future<UpdateInfo?> fetchLatest() async {
  final apk = _apkName(await Core.abi());
  // 1) GitHub API (has the release notes)
  try {
    final r = await http.get(
      Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'),
      headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'DastRasNG'},
    ).timeout(const Duration(seconds: 12));
    if (r.statusCode == 200) {
      final j = jsonDecode(r.body) as Map;
      final tag = (j['tag_name'] ?? '').toString();
      String? url;
      String? uni;
      for (final a in (j['assets'] as List? ?? const [])) {
        if (a is Map && a['name'] == apk) url = a['browser_download_url']?.toString();
        if (a is Map && a['name'] == 'app-universal-release.apk') uni = a['browser_download_url']?.toString();
      }
      url ??= uni ?? 'https://github.com/$kRepo/releases/download/$tag/$apk';
      if (tag.isNotEmpty) return UpdateInfo(_buildOf(tag), tag, (j['body'] ?? '').toString(), url);
    }
  } catch (_) {}
  // 2) fallback: the plain github.com redirect to the latest tag
  try {
    final client = http.Client();
    final req = http.Request('GET', Uri.parse('https://github.com/$kRepo/releases/latest'))..followRedirects = false;
    final resp = await client.send(req).timeout(const Duration(seconds: 12));
    final loc = resp.headers['location'] ?? '';
    client.close();
    final m = RegExp(r'/releases/tag/([^/?#]+)').firstMatch(loc);
    if (m != null) {
      final tag = m.group(1)!;
      return UpdateInfo(_buildOf(tag), tag, '', 'https://github.com/$kRepo/releases/download/$tag/$apk');
    }
  } catch (_) {}
  return null;
}

/// The newest release if it is newer than this build, otherwise null.
Future<UpdateInfo?> checkUpdate() async {
  final l = await fetchLatest();
  if (l == null) return null;
  return l.build > kBuild ? l : null;
}

class UpdatePage extends StatefulWidget {
  final UpdateInfo? info; // null = check first
  const UpdatePage({super.key, this.info});
  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  UpdateInfo? info;
  bool checking = false;
  bool checked = false;
  bool downloading = false;
  double progress = 0;
  String? message;

  @override
  void initState() {
    super.initState();
    info = widget.info;
    if (info == null) _check();
  }

  Future<void> _check() async {
    setState(() {
      checking = true;
      message = null;
    });
    final u = await checkUpdate();
    if (!mounted) return;
    setState(() {
      info = u;
      checking = false;
      checked = true;
    });
  }

  Future<void> _install() async {
    final i = info;
    if (i == null || downloading) return;
    setState(() {
      downloading = true;
      progress = 0;
      message = null;
    });
    try {
      final dir = Directory('${await Core.cacheDir()}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final file = File('${dir.path}/app.${Platform.isWindows ? 'zip' : 'apk'}');
      final client = http.Client();
      final resp = await client.send(http.Request('GET', Uri.parse(i.url))).timeout(const Duration(seconds: 30));
      if (resp.statusCode != 200) throw Exception('HTTP ${resp.statusCode}');
      final total = resp.contentLength ?? 0;
      var got = 0;
      final sink = file.openWrite();
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0 && mounted) setState(() => progress = got / total);
      }
      await sink.close();
      client.close();
      final r = await Core.installApk(file.path);
      if (!mounted) return;
      setState(() {
        downloading = false;
        message = r == 'needs_permission' ? tr('update_perm') : (r == 'ok' ? tr('update_signed') : r);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        downloading = false;
        message = '${tr('update_fail')}: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) => Scaffold(
          body: Backdrop(
            child: SafeArea(
              child: Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                  child: Row(children: [
                    IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
                    Text(tr('app_update'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Pal.t1)),
                  ]),
                ),
                Expanded(
                  child: ListView(padding: const EdgeInsets.all(20), children: [
                    const Center(child: Pop(child: Logo(size: 96))),
                    const SizedBox(height: 14),
                    Center(
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text('${tr('version')} $kVersion  (build $kBuild)',
                            style: TextStyle(fontSize: 15, color: Pal.t3)),
                      ),
                    ),
                    const SizedBox(height: 18),
                    if (checking)
                      Center(child: Text(tr('update_checking'), style: TextStyle(color: Pal.t2)))
                    else if (info != null) ...[
                      Glass(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Icon(Icons.system_update_rounded, color: Pal.green),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(tr('update_available'),
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: Pal.t1)),
                            ),
                          ]),
                          const SizedBox(height: 6),
                          Directionality(
                            textDirection: TextDirection.ltr,
                            child: Text(info!.tag, style: TextStyle(color: Pal.t3)),
                          ),
                          if (info!.notes.trim().isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Text(tr('whats_new'), style: TextStyle(fontWeight: FontWeight.w700, color: Pal.t1)),
                            const SizedBox(height: 4),
                            Text(info!.notes.trim(), style: TextStyle(height: 1.5, color: Pal.t2)),
                          ],
                        ]),
                      ),
                      const SizedBox(height: 16),
                      if (downloading) ...[
                        LinearProgressIndicator(value: progress > 0 ? progress : null, minHeight: 6),
                        const SizedBox(height: 8),
                        Center(child: Text('${tr('update_downloading')} ${(progress * 100).toStringAsFixed(0)}%',
                            style: TextStyle(color: Pal.t2))),
                      ] else
                        FilledButton.icon(
                          onPressed: _install,
                          icon: const Icon(Icons.download_rounded),
                          label: Text(tr('update_now')),
                        ),
                    ] else if (checked)
                      Center(child: Text(tr('update_latest'), style: TextStyle(fontSize: 16, color: Pal.green)))
                    else
                      Center(child: Text(tr('update_fail'), style: TextStyle(color: Pal.t3))),
                    if (message != null) ...[
                      const SizedBox(height: 14),
                      Text(message!, textAlign: TextAlign.center, style: TextStyle(color: Pal.t2, height: 1.5)),
                    ],
                    const SizedBox(height: 16),
                    if (!checking && info == null)
                      Center(child: TextButton.icon(onPressed: _check, icon: const Icon(Icons.refresh_rounded), label: Text(tr('check_update')))),
                  ]),
                ),
              ]),
            ),
          ),
        ));
  }
}
