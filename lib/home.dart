import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'core.dart';
import 'lang.dart';
import 'main.dart' show kAppName, kChannelUser, openTelegram;
import 'models.dart';
import 'service.dart';
import 'settings_page.dart';
import 'apps_page.dart';
import 'theme.dart';

String fmtBytes(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < 4) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i <= 1 ? 0 : 1)} ${u[i]}';
}

String fmtRate(int b) => '${fmtBytes(b)}/s';
String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

Color pingColor(int? d) {
  if (d == null) return Colors.white38;
  if (d < 150) return kGreen;
  if (d < 500) return kOrange;
  return const Color(0xFFFF6B6B);
}

bool looksLikeConfig(String t) {
  final x = t.trim();
  if (x.isEmpty || x.length > 20000) return false;
  const schemes = ['vless://', 'vmess://', 'trojan://', 'ss://', 'hy2://', 'hysteria2://', 'hysteria://', 'tuic://', 'wireguard://', 'socks://'];
  final low = x.toLowerCase();
  for (final s in schemes) {
    if (low.startsWith(s)) return true;
  }
  return !x.contains('\n') && !x.contains(' ') && (low.startsWith('http://') || low.startsWith('https://')) && x.length > 24;
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  final store = Store();
  bool ready = false;
  bool busy = false;
  bool preparing = false;
  bool cancel = false;
  String phase = ''; // '' | updating | testing
  bool expanded = true;
  String status = 'stopped';
  String? lastShownError;
  String? clipCand;
  Traffic traffic = Traffic.zero;
  Timer? timer;
  Timer? refreshTimer;
  bool _refreshing = false;

  bool get running => status == 'running';
  bool get starting => status == 'starting';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    refreshTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && ready) _checkClipboard();
  }

  Future<void> _init() async {
    await store.load();
    status = await Core.status();
    if (!mounted) return;
    setState(() => ready = true);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _checkClipboard();
    _maybeRefresh();
    refreshTimer = Timer.periodic(const Duration(minutes: 5), (_) => _maybeRefresh());
    if (store.connectOnOpen && !running && !starting && (store.nodes.isNotEmpty || store.subs.isNotEmpty)) {
      _toggle();
    }
  }

  static const _refreshEvery = Duration(hours: 3);

  bool get _stale {
    if (!store.autoUpdate || store.subs.isEmpty) return false;
    if (store.updatedMs == 0) return true;
    final age = DateTime.now().millisecondsSinceEpoch - store.updatedMs;
    return age >= _refreshEvery.inMilliseconds;
  }

  /// Subscription refresh: once when the app opens (if older than 3 hours) and then every 3 hours.
  Future<void> _maybeRefresh() async {
    if (!_stale || _refreshing) return;
    await _refreshSubs(silent: true);
  }

  Future<void> _poll() async {
    final s = await Core.status();
    if (!mounted) return;
    Traffic t = traffic;
    if (s == 'running') {
      t = await Core.stats();
    } else if (traffic.totDown != 0 || traffic.down != 0) {
      t = Traffic.zero;
    }
    if (!mounted) return;
    if (s != status || t.down != traffic.down || t.up != traffic.up) {
      setState(() {
        status = s;
        traffic = t;
      });
    }
    if (s.startsWith('error:') && s != lastShownError) {
      lastShownError = s;
      _toast('${tr('error')}: ${s.substring(6)}');
    }
  }

  Future<void> _checkClipboard() async {
    if (!store.clipboardWatch) return;
    try {
      final d = await Clipboard.getData('text/plain');
      final t = d?.text?.trim();
      if (t == null || t.isEmpty || t == store.lastClip) return;
      if (!looksLikeConfig(t)) return;
      if (mounted) setState(() => clipCand = t);
    } catch (_) {}
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  // ---------- connect flow ----------

  Future<void> _toggle() async {
    if (preparing) {
      cancel = true;
      return;
    }
    if (running || starting) {
      await Core.stop();
      return;
    }
    if (store.nodes.isEmpty && store.subs.isEmpty) {
      _toast(tr('need_config'));
      return;
    }
    preparing = true;
    cancel = false;
    try {
      // 1) refresh the subscription only if it is older than 3 hours
      if (_stale) {
        setState(() => phase = 'updating');
        try {
          await _maybeRefresh().timeout(const Duration(seconds: 15));
        } catch (_) {}
      }
      if (cancel) return;
      if (store.nodes.isEmpty) {
        _toast(tr('need_config'));
        return;
      }
      // 2) pick the best, most stable server
      if (store.autoSelect && store.nodes.length > 1) {
        setState(() => phase = 'testing');
        try {
          await _autoSelect().timeout(const Duration(seconds: 20));
        } catch (_) {}
      }
      if (cancel) return;
      await _startSelected();
    } finally {
      preparing = false;
      if (mounted) setState(() => phase = '');
    }
  }

  Future<void> _startSelected() async {
    if (store.nodes.isEmpty) return;
    if (store.selected >= store.nodes.length) store.selected = 0;
    lastShownError = null;
    final node = store.nodes[store.selected];
    final res = await Core.start(
      buildConfig(node.ob, store),
      mode: store.perAppMode,
      apps: store.perAppList.toList(),
      dns: dnsList(store),
      ipv6: store.ipv6,
      lang: langN.value,
    );
    if (res == 'denied') _toast(tr('vpn_denied'));
  }

  /// Tapping another server: if already connected, switch to it automatically.
  Future<void> _select(int i) async {
    if (i == store.selected) return;
    store.selected = i;
    await store.save();
    if (mounted) setState(() {});
    if ((running || starting) && !preparing) await _switchServer();
  }

  Future<void> _switchServer() async {
    preparing = true;
    if (mounted) setState(() => phase = 'switching');
    try {
      await Core.stop();
      for (var k = 0; k < 40; k++) {
        await Future.delayed(const Duration(milliseconds: 150));
        if (await Core.status() == 'stopped') break;
      }
      await Future.delayed(const Duration(milliseconds: 600));
      await _startSelected();
    } finally {
      preparing = false;
      if (mounted) setState(() => phase = '');
    }
  }

  /// TCP-tests every server (fast, parallel), then runs a real delay test on the
  /// best candidates and picks the lowest delay, penalising unstable ones.
  Future<void> _autoSelect() async {
    final nodes = store.nodes;
    await tcpPingAll(nodes, samples: 2);
    if (cancel) return;

    var cand = <int>[
      for (var i = 0; i < nodes.length; i++)
        if (nodes[i].stat == null || nodes[i].stat!.ok > 0) i
    ];
    if (cand.isEmpty) cand = List<int>.generate(nodes.length, (i) => i); // UDP protocols etc.
    cand.sort((a, b) => (nodes[a].stat?.score ?? 5000).compareTo(nodes[b].stat?.score ?? 5000));
    cand = cand.take(5).toList();

    int best = cand.first;
    try {
      final real = await pingBatch(cand.map((i) => nodes[i].ob).toList(), store.testUrl);
      var bestScore = double.infinity;
      for (var k = 0; k < cand.length; k++) {
        final n = nodes[cand[k]];
        n.real = real[k];
        if (real[k] == null) continue;
        final jitter = n.stat == null ? 0 : (n.stat!.max - n.stat!.min);
        final score = real[k]! + jitter * 2.0 + ((n.stat?.total ?? 0) - (n.stat?.ok ?? 0)) * 500;
        if (score < bestScore) {
          bestScore = score;
          best = cand[k];
        }
      }
    } catch (_) {}
    store.selected = best;
    await store.save();
    if (mounted) setState(() {});
  }

  Future<void> _refreshSubs({bool silent = false}) async {
    if (store.subs.isEmpty) {
      if (!silent) _toast(tr('no_sub'));
      return;
    }
    if (_refreshing) return;
    _refreshing = true;
    if (!silent && mounted) setState(() => busy = true);
    try {
      final selKey = store.nodes.isNotEmpty && store.selected < store.nodes.length
          ? store.nodes[store.selected].key
          : null;
      final old = {for (final n in store.nodes) n.key: n};
      final all = <Node>[];
      SubInfo? info;
      String? title;
      for (final url in store.subs) {
        final r = await fetchAndParse(url);
        if (r.title != null && r.title!.trim().isNotEmpty) title ??= r.title!.trim();
        for (final o in r.obs) {
          final n = Node(o, 'sub');
          final p = old[n.key];
          if (p != null) {
            n.tcp = p.tcp;
            n.real = p.real;
            n.stat = p.stat;
            n.tested = p.tested;
          }
          all.add(n);
        }
        if (r.info != null) info = r.info;
      }
      store.nodes = [...store.nodes.where((n) => n.src != 'sub'), ...all];
      final idx = selKey == null ? -1 : store.nodes.indexWhere((n) => n.key == selKey);
      store.selected = idx >= 0 ? idx : 0;
      store.info = info;
      if (title != null) store.subTitle = title;
      store.updatedMs = DateTime.now().millisecondsSinceEpoch;
      await store.save();
      if (!silent) _toast('${tr('sub_updated')} (${all.length} ${tr('configs_n')})');
    } catch (e) {
      if (!silent) _toast('${tr('error')}: $e');
    } finally {
      _refreshing = false;
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addText(String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    final isSub = !text.contains('\n') && (text.startsWith('http://') || text.startsWith('https://'));
    if (isSub && text.startsWith('http://') && store.httpsOnly) {
      _toast(tr('https_only_warn'));
      return;
    }
    setState(() => busy = true);
    try {
      if (isSub) {
        if (!store.subs.contains(text)) store.subs.add(text);
        await store.save();
        await _refreshSubs();
      } else {
        final obs = await convert(text);
        store.nodes.addAll(obs.map((o) => Node(o, 'manual')));
        await store.save();
        _toast('${obs.length} ${tr('added_n')}');
      }
    } catch (e) {
      _toast('${tr('error')}: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _ping() async {
    if (store.nodes.isEmpty) return;
    setState(() => busy = true);
    try {
      final selKey = store.nodes[store.selected].key;
      await tcpPingAll(store.nodes, samples: 3);
      if (store.pingMode == 'real') {
        if (running || starting) {
          _toast(tr('disconnect_first'));
        } else {
          final res = await pingBatch(store.nodes.map((n) => n.ob).toList(), store.testUrl);
          for (var i = 0; i < store.nodes.length && i < res.length; i++) {
            store.nodes[i].real = res[i];
          }
        }
      }
      if (store.nodes.any((n) => n.delay != null)) {
        final sorted = List<Node>.from(store.nodes)
          ..sort((a, b) {
            final x = a.delay, y = b.delay;
            if (x == null && y == null) return 0;
            if (x == null) return 1;
            if (y == null) return -1;
            return x.compareTo(y);
          });
        store.nodes = sorted;
        final idx = sorted.indexWhere((n) => n.key == selKey);
        store.selected = store.autoSelect ? 0 : (idx >= 0 ? idx : 0);
      }
      await store.save();
    } catch (e) {
      _toast('${tr('error')}: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------- dialogs / sheets ----------

  void _addDialog() {
    final c = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('add_config')),
        content: TextField(
          controller: c,
          maxLines: 6,
          minLines: 3,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(hintText: tr('add_hint'), border: const OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final d = await Clipboard.getData('text/plain');
              if (d?.text != null) c.text = d!.text!;
            },
            child: Text(tr('paste')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _addText(c.text);
            },
            child: Text(tr('add')),
          ),
        ],
      ),
    );
  }

  void _nodeDetails(int i) {
    final n = store.nodes[i];
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF151D40),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.name, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(n.subtitle, style: const TextStyle(color: Colors.white60)),
            if (n.address.isNotEmpty) ...[
              const SizedBox(height: 4),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(n.address, style: const TextStyle(color: Colors.white60)),
              ),
            ],
            if (n.tcp != null || n.real != null) ...[
              const SizedBox(height: 8),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  'TCP: ${n.tcp != null ? '${n.tcp} ms' : '—'}    URL: ${n.real != null ? '${n.real} ms' : '—'}',
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                icon: const Icon(Icons.delete_outline_rounded, color: Color(0xFFFF6B6B)),
                label: Text(tr('delete'), style: const TextStyle(color: Color(0xFFFF6B6B))),
                onPressed: () async {
                  Navigator.pop(ctx);
                  store.nodes.removeAt(i);
                  if (store.selected >= store.nodes.length) store.selected = 0;
                  await store.save();
                  if (mounted) setState(() {});
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Tr((context) {
      final h = MediaQuery.of(context).size.height;
      final label = phase == 'updating'
          ? tr('updating_sub')
          : phase == 'testing'
              ? tr('auto_testing')
              : phase == 'switching'
                  ? tr('switching')
              : running
                  ? tr('connected')
                  : starting
                      ? tr('connecting')
                      : tr('tap_connect');
      final busyPhase = phase.isNotEmpty;
      final labelColor = running ? kGreen : (starting || busyPhase ? kOrange : Colors.white70);
      return Scaffold(
        body: Backdrop(
          child: SafeArea(
            child: !ready
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    _topBar(),
                    if (clipCand != null) _clipBanner(),
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            SizedBox(
                              width: 168,
                              height: 168,
                              child: FittedBox(
                                child: PowerButton(on: running, loading: starting || busyPhase, onTap: _toggle),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(label, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, color: labelColor)),
                            const SizedBox(height: 8),
                            if (running) _speedRow(),
                            if (running) const SizedBox(height: 8),
                            _selectedChip(),
                          ]),
                        ),
                      ),
                    ),
                    _sheet(h),
                  ]),
          ),
        ),
      );
    });
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
      child: Row(children: [
        const Logo(size: 34),
        const SizedBox(width: 10),
        const Text(kAppName, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(
          tooltip: tr('add_config'),
          onPressed: _addDialog,
          icon: const Icon(Icons.add_circle_outline_rounded, size: 27),
        ),
        IconButton(
          tooltip: tr('per_app'),
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => AppsPage(store: store))),
          icon: Badge(
            isLabelVisible: store.perAppMode != 'all',
            smallSize: 9,
            child: const Icon(Icons.apps_rounded, size: 27),
          ),
        ),
        IconButton(
          tooltip: tr('settings'),
          onPressed: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsPage(store: store)));
            if (mounted) setState(() {});
          },
          icon: const Icon(Icons.settings_rounded, size: 27),
        ),
      ]),
    );
  }

  Widget _clipBanner() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0x335B8CFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGlassBorder),
      ),
      child: Row(children: [
        const Icon(Icons.content_paste_go_rounded, color: kCyan),
        const SizedBox(width: 10),
        Expanded(child: Text(tr('clip_found'), style: const TextStyle(fontSize: 14.5))),
        TextButton(
          onPressed: () async {
            final t = clipCand!;
            store.lastClip = t;
            setState(() => clipCand = null);
            await store.save();
            _addText(t);
          },
          child: Text(tr('add')),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () async {
            store.lastClip = clipCand!;
            setState(() => clipCand = null);
            await store.save();
          },
        ),
      ]),
    );
  }

  Widget _speedRow() {
    Widget item(IconData ic, Color c, String txt) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 18, color: c),
          const SizedBox(width: 4),
          Text(txt, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
        ]);
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          item(Icons.arrow_downward_rounded, kGreen, fmtRate(traffic.down)),
          const SizedBox(width: 22),
          item(Icons.arrow_upward_rounded, kCyan, fmtRate(traffic.up)),
        ]),
        const SizedBox(height: 2),
        Text(
          '${tr('session')}: ${fmtBytes(traffic.totDown + traffic.totUp)}',
          style: const TextStyle(fontSize: 12.5, color: Colors.white54),
        ),
      ]),
    );
  }

  Widget _selectedChip() {
    Node? n;
    if (store.nodes.isNotEmpty && store.selected < store.nodes.length) n = store.nodes[store.selected];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: kGlass,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: kGlassBorder),
      ),
      child: n == null
          ? Text(tr('no_servers'), style: const TextStyle(color: Colors.white54))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Text(n.flag ?? '🌐', style: const TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16)),
              ),
              if (n.delay != null) ...[
                const SizedBox(width: 8),
                Text('${n.delay}ms', style: TextStyle(fontSize: 13.5, color: pingColor(n.delay))),
              ],
            ]),
    );
  }

  Widget _sheet(double h) {
    return Container(
      height: expanded ? h * 0.56 : null,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xE60F1736), Color(0xF20A1030)],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
        border: Border(top: BorderSide(color: kGlassBorder)),
        boxShadow: [BoxShadow(color: Color(0x66000000), blurRadius: 30, offset: Offset(0, -8))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 38,
          height: 4,
          margin: const EdgeInsets.only(top: 8),
          decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
        ),
        _sheetHeader(),
        if (busy) const LinearProgressIndicator(minHeight: 2),
        if (expanded) ...[
          _infoBar(),
          Expanded(child: _list()),
        ],
      ]),
    );
  }

  Widget _sheetHeader() {
    final upd = store.updatedMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(store.updatedMs);
    final title = store.subTitle.isNotEmpty ? store.subTitle : tr('subscription');
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 2),
      child: Row(children: [
        IconButton(
          onPressed: () => setState(() => expanded = !expanded),
          icon: AnimatedRotation(
            turns: expanded ? 0 : -0.5,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: kCyan),
          ),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: kGlass, borderRadius: BorderRadius.circular(10)),
                child: Text('${store.nodes.length}', style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
              ),
            ]),
            if (upd != null)
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text('${fmtDate(upd)} ${two(upd.hour)}:${two(upd.minute)}',
                    style: const TextStyle(fontSize: 12, color: Colors.white38)),
              ),
          ]),
        ),
        IconButton(
          tooltip: tr('update_sub'),
          onPressed: busy ? null : () => _refreshSubs(),
          icon: const Icon(Icons.sync_rounded, color: kCyan),
        ),
        IconButton(
          tooltip: tr('test_ping'),
          onPressed: busy ? null : _ping,
          icon: const Icon(Icons.speed_rounded, color: kCyan),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz_rounded, color: kCyan),
          onSelected: (v) async {
            if (v == 'clear') {
              store.nodes = [];
              store.subs = [];
              store.selected = 0;
              store.info = null;
              store.subTitle = '';
              store.updatedMs = 0;
              await store.save();
              if (mounted) setState(() {});
            } else if (v == 'add') {
              _addDialog();
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'add', child: Text(tr('add_config'))),
            PopupMenuItem(value: 'clear', child: Text(tr('delete_all'))),
          ],
        ),
      ]),
    );
  }

  Widget _infoBar() {
    final i = store.info;
    final used = i?.used ?? 0;
    final total = i?.total ?? 0;
    final exp = (i != null && i.expire > 0)
        ? fmtDate(DateTime.fromMillisecondsSinceEpoch(i.expire * 1000))
        : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0x1A5B8CFF),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGlassBorder),
      ),
      child: Row(children: [
        const Icon(Icons.data_usage_rounded, color: kAccent, size: 22),
        const SizedBox(width: 10),
        if (i != null)
          Expanded(
            child: Stack(alignment: Alignment.center, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  minHeight: 22,
                  value: total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0,
                  backgroundColor: const Color(0x14FFFFFF),
                  color: const Color(0x665B8CFF),
                ),
              ),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text('${fmtBytes(used)} / ${total > 0 ? fmtBytes(total) : '∞'}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
            ]),
          )
        else
          const Expanded(child: SizedBox()),
        if (exp != null) ...[
          const SizedBox(width: 10),
          Text('${tr('expires')}: $exp', style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
        ],
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => openTelegram(kChannelUser),
          icon: const Icon(Icons.send_rounded, color: kCyan, size: 22),
        ),
      ]),
    );
  }

  Widget _list() {
    if (store.nodes.isEmpty) {
      return Center(
        child: Text(
          tr('no_config'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 18, top: 2),
      itemCount: store.nodes.length,
      itemBuilder: (_, i) {
        final n = store.nodes[i];
        final sel = i == store.selected;
        final d = n.delay;
        final pingText = d != null ? '${d}ms' : (n.tested ? 'n/a' : '');
        final pc = pingColor(d);
        return Container(
          margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
          decoration: BoxDecoration(
            color: sel ? const Color(0x265B8CFF) : kGlass,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: sel ? kAccent.withValues(alpha: 0.8) : kGlassBorder, width: sel ? 1.4 : 1),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () => _select(i),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
                child: Row(children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: const Color(0x14FFFFFF),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: n.flag != null
                        ? Text(n.flag!, style: const TextStyle(fontSize: 24))
                        : const Icon(Icons.public_rounded, color: Colors.white54),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          if (sel && running)
                            Container(
                              width: 8,
                              height: 8,
                              margin: const EdgeInsetsDirectional.only(end: 6),
                              decoration: const BoxDecoration(color: kGreen, shape: BoxShape.circle),
                            ),
                          Flexible(
                            child: Text(n.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                          ),
                        ]),
                        const SizedBox(height: 2),
                        Text(n.subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12, color: Colors.white38)),
                      ],
                    ),
                  ),
                  if (pingText.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: pc.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(pingText,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: pc)),
                      ),
                    ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _nodeDetails(i),
                    icon: const Icon(Icons.more_vert_rounded, color: Colors.white38, size: 20),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}
