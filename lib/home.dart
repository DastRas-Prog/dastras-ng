import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' show FontFeature, ImageFilter;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'announce.dart';
import 'apps_page.dart';
import 'config.dart';
import 'core.dart';
import 'inbox_page.dart';
import 'jalali.dart';
import 'qr_pages.dart';
import 'lang.dart';
import 'main.dart' show kAppName, kChannelUser, kSupportUser, openTelegram, openTelegramText;
import 'models.dart';
import 'pal.dart';
import 'service.dart';
import 'settings_page.dart';
import 'theme.dart';
import 'update.dart';

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
String fmtDate(DateTime d) => formatDate(d);

Color pingColor(int? d) {
  if (d == null) return Pal.t4;
  if (d < 150) return Pal.green;
  if (d < 500) return Pal.orange;
  return Pal.red;
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
  String phase = ''; // '' | updating | testing | switching
  DateTime? connectedAt;
  int tab = 0; // 0 home, 1 servers, 2 apps, 3 inbox, 4 settings
  int _inboxMark = -1;
  String status = 'stopped';
  String? lastShownError;
  String? clipCand;
  Announcement? annCand;
  UpdateInfo? updCand;
  DateTime _lastUpd = DateTime.fromMillisecondsSinceEpoch(0);
  Traffic traffic = Traffic.zero;
  final List<int> downHist = [];
  Timer? timer;
  Timer? refreshTimer;
  bool _refreshing = false;
  DateTime _lastAnn = DateTime.fromMillisecondsSinceEpoch(0);

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
    if (state == AppLifecycleState.resumed && ready) {
      _checkClipboard();
      _checkAnn();
    }
  }

  Future<void> _init() async {
    await store.load();
    status = await Core.status();
    if (!mounted) return;
    setState(() => ready = true);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    _checkClipboard();
    _checkWarn();
    if (_newDay) {
      _refreshSubs(silent: true);
    } else {
      _maybeRefresh();
    }
    _checkAnn();
    Future.delayed(const Duration(seconds: 4), _checkAppUpdate);
    refreshTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      _maybeRefresh();
      _checkAnn();
      _checkAppUpdate();
    });
    if (store.connectOnOpen && !running && !starting && (store.nodes.isNotEmpty || store.subs.isNotEmpty)) {
      _toggle();
    }
  }

  bool get _stale {
    if (!store.autoUpdate || store.subs.isEmpty) return false;
    if (store.updatedMs == 0) return true;
    if (store.updateEveryMin <= 0) return false; // only the first open of each day
    final age = DateTime.now().millisecondsSinceEpoch - store.updatedMs;
    return age >= store.updateEveryMin * 60000;
  }

  /// True the first time the app opens on a new calendar day.
  bool get _newDay {
    if (!store.autoUpdate || store.subs.isEmpty) return false;
    if (store.updatedMs == 0) return true;
    final u = DateTime.fromMillisecondsSinceEpoch(store.updatedMs);
    final n = DateTime.now();
    return u.year != n.year || u.month != n.month || u.day != n.day;
  }

  // ---------- app update (new release on GitHub) ----------

  /// Puts a "new version" message in the inbox (once per version) and posts one notification.
  Future<void> _addUpdateMessage(UpdateInfo u) async {
    final id = 1000000 + u.build;
    if (store.annDeleted.contains(id)) return;
    final list = (jsonDecode(store.sysJson) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    if (list.any((m) => m['id'] == id)) return;
    list.insert(0, {
      'id': id,
      'title': tr('update_available'),
      'body': '${tr('version')} ${u.tag}${u.notes.trim().isEmpty ? '' : '\n${u.notes.trim()}'}',
      'url': kUpdateUrl,
      'date': formatDate(DateTime.now()),
    });
    store.sysJson = jsonEncode(list.take(10).toList());
    if (store.updNotified < u.build) {
      store.updNotified = u.build;
      try {
        await Core.notify(tr('update_available'), '${tr('version')} ${u.tag}', id: 3002);
      } catch (_) {}
    }
    await store.save();
    if (mounted) setState(() {});
  }

  Future<void> _checkAppUpdate() async {
    if (kBuild == 0) return; // local dev build
    if (DateTime.now().difference(_lastUpd).inHours < 6) return;
    _lastUpd = DateTime.now();
    try {
      final u = await checkUpdate();
      if (u != null && mounted) {
        setState(() => updCand = u);
        _addUpdateMessage(u);
      }
    } catch (_) {}
  }

  /// Subscription refresh: once when the app opens (if older than 3 hours) and then every 3 hours.
  Future<void> _maybeRefresh() async {
    if (!_stale || _refreshing) return;
    await _refreshSubs(silent: true);
  }

  // ---------- announcements (messages to customers) ----------

  int get _unread {
    final items = allMessages(store.annJson, store.sysJson);
    return items.where((a) => !store.annDeleted.contains(a.id) && !store.annReadIds.contains(a.id)).length;
  }

  Future<void> _checkAnn() async {
    if (!store.announceOn) return;
    if (DateTime.now().difference(_lastAnn).inMinutes < 10) return;
    _lastAnn = DateTime.now();
    try {
      final raw = await Core.announceCheck(kAnnounceUrls, notify: false);
      if (raw == null) return;
      final items = parseAnnouncements(raw);
      store.annJson = raw;
      if (items.isEmpty) {
        if (store.annRead == -1) store.annRead = 0;
        await store.save();
        return;
      }
      if (store.annRead == -1) {
        store.annRead = 0; // first run: old messages count as read, do not flood the user
        store.annReadIds.addAll(items.map((a) => a.id));
      } else {
        final fresh = items.where((a) => !store.annDeleted.contains(a.id) && !store.annReadIds.contains(a.id)).toList();
        if (fresh.isNotEmpty && mounted) annCand = fresh.first;
      }
      await store.save();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _markAllRead() async {
    final items = allMessages(store.annJson, store.sysJson);
    for (final a in items) {
      if (!store.annDeleted.contains(a.id)) store.annReadIds.add(a.id);
    }
    annCand = null;
    await store.save();
    if (mounted) setState(() {});
  }

  Future<void> _poll() async {
    try {
      await _pollInner();
    } catch (_) {}
  }

  Future<void> _pollInner() async {
    final s = await Core.status();
    if (!mounted) return;
    var t = traffic;
    if (s == 'running') {
      t = await Core.stats();
      downHist.add(t.down);
      if (downHist.length > 40) downHist.removeAt(0);
    } else {
      if (downHist.isNotEmpty) downHist.clear();
      t = Traffic.zero;
    }
    if (!mounted) return;
    if (s == 'running') {
      connectedAt ??= DateTime.now();
    } else {
      connectedAt = null;
    }
    if (s != status || s == 'running' || t.down != traffic.down || t.up != traffic.up) {
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
    String cfg;
    try {
      cfg = buildConfig(node.ob, store);
    } catch (e) {
      _toast('${tr('error')}: $e');
      return;
    }
    final res = await Core.start(
      cfg,
      mode: store.perAppMode,
      apps: store.perAppList.toList(),
      dns: dnsList(store),
      ipv6: store.ipv6,
      mtu: store.mtu,
      lang: langN.value,
      announceUrls: store.announceOn ? kAnnounceUrls : const [],
    );
    if (res == 'denied') _toast(tr('vpn_denied'));
  }

  /// Tapping another server: if already connected, switch to it automatically.
  Future<void> _select(int i) async {
    if (i == store.selected) return;
    HapticFeedback.selectionClick();
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
        if (!nodes[i].isInfo && (nodes[i].stat == null || nodes[i].stat!.ok > 0)) i
    ];
    if (cand.isEmpty) cand = List<int>.generate(nodes.length, (i) => i).where((i) => !nodes[i].isInfo).toList();
    if (cand.isEmpty) return;

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
        final r = await fetchAndParse(url, preferJson: store.panelTuning);
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
      _checkWarn();
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
        final lines = text.split(RegExp(r'[\r\n]+')).map((e) => e.trim()).where((e) => e.contains('://')).toList();
        store.nodes.addAll([
          for (var k = 0; k < obs.length; k++) Node(obs[k], 'manual')..link = (obs.length == lines.length ? lines[k] : null),
        ]);
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

  void _nodeDetails(int i) {
    final n = store.nodes[i];
    showModalBottomSheet(
      context: context,
      backgroundColor: Pal.dialog,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.name, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Pal.t1)),
            const SizedBox(height: 6),
            Text(n.subtitle, style: TextStyle(color: Pal.t2)),
            if (n.address.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(children: [
                Directionality(textDirection: TextDirection.ltr, child: Text(n.address, style: TextStyle(color: Pal.t2))),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: tr('copy_address'),
                  icon: Icon(Icons.copy_rounded, size: 18, color: Pal.cyan),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: n.address));
                    _toast(tr('copied'));
                  },
                ),
              ]),
            ],
            if (n.tcp != null || n.real != null) ...[
              const SizedBox(height: 8),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  'TCP: ${n.tcp != null ? '${n.tcp} ms' : '—'}    URL: ${n.real != null ? '${n.real} ms' : '—'}',
                  style: TextStyle(color: Pal.t2),
                ),
              ),
            ],
            if (n.link != null) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () => showQrDialog(context, n.name, n.link!),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                  label: const Text('QR'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: n.link!));
                    _toast(tr('copied'));
                  },
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  label: Text(tr('copy_link')),
                ),
                OutlinedButton.icon(
                  onPressed: () => Core.share(n.link!),
                  icon: const Icon(Icons.share_rounded, size: 18),
                  label: Text(tr('share')),
                ),
              ]),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                icon: Icon(Icons.delete_outline_rounded, color: Pal.red),
                label: Text(tr('delete'), style: TextStyle(color: Pal.red)),
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

  // ---------- account warning (low data / about to expire) ----------

  String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  String? get _warnText {
    final i = store.info;
    if (i == null) return null;
    final parts = <String>[];
    if (i.total > 0) {
      final left = i.total - i.used;
      if (left <= 2 * 1024 * 1024 * 1024) {
        parts.add(left <= 0 ? tr('warn_data_over') : '${tr('warn_data_left')}: ${fmtBytes(left)}');
      }
    }
    if (i.expire > 0) {
      final secs = i.expire - DateTime.now().millisecondsSinceEpoch ~/ 1000;
      if (secs <= 2 * 86400) {
        parts.add(secs <= 0 ? tr('warn_expired') : '${tr('warn_days_left')}: ${(secs / 86400).ceil()} ${tr('days')}');
      }
    }
    return parts.isEmpty ? null : parts.join(' • ');
  }

  bool get _warnVisible => _warnText != null && store.warnDismissDay != _today();

  static const _supportMsg = 'درود وقت بخیر، اکانت من داره تموم میشه لطفا اکانت منو شارژ کنید.';

  /// Opens the support chat in Telegram with the recharge message ready (also copied).
  Future<void> _contactSupport() async {
    await Clipboard.setData(const ClipboardData(text: _supportMsg));
    _toast(tr('support_msg_copied'));
    await openTelegramText(kSupportUser, _supportMsg);
  }

  /// At most one system notification per day.
  Future<void> _checkWarn() async {
    final w = _warnText;
    if (w == null || store.warnedDay == _today()) return;
    store.warnedDay = _today();
    await store.save();
    try {
      await Core.notify(tr('warn_title'), '$w\n${tr('warn_notify_body')}', id: 3001);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Widget _warnBanner() => _banner(
        icon: Icons.warning_amber_rounded,
        tint: Pal.orange,
        text: '${tr('warn_title')}: ${_warnText ?? ''}',
        action: tr('warn_charge'),
        onAction: _contactSupport,
        onClose: () async {
          store.warnDismissDay = _today();
          await store.save();
          if (mounted) setState(() {});
        },
      );

  /// Automatic = best server is picked for you; Manual = you choose from the server list.
  Widget _modeToggle() {
    return SizedBox(
      width: 300,
      child: SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: [
          ButtonSegment(value: true, icon: const Icon(Icons.auto_awesome_rounded, size: 18), label: Text(tr('mode_auto'))),
          ButtonSegment(value: false, icon: const Icon(Icons.touch_app_rounded, size: 18), label: Text(tr('mode_manual'))),
        ],
        selected: {store.autoSelect},
        onSelectionChanged: (v) async {
          HapticFeedback.selectionClick();
          store.autoSelect = v.first;
          await store.save();
          if (mounted) setState(() {});
          if (!v.first) _goTab(1); // manual: pick the server yourself
        },
      ),
    );
  }

  void _linksSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.dialog,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('sub_links'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Pal.t1)),
              const SizedBox(height: 12),
              if (store.subs.isEmpty)
                Padding(padding: const EdgeInsets.all(12), child: Text(tr('no_links'), style: TextStyle(color: Pal.t3))),
              for (final url in List<String>.from(store.subs))
                Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.fromLTRB(12, 10, 6, 4),
                  decoration: BoxDecoration(
                    color: Pal.card,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Pal.cardBorder),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: SelectableText(url, maxLines: 3, style: TextStyle(fontSize: 13, color: Pal.t2)),
                    ),
                    Row(children: [
                      TextButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: url));
                          _toast(tr('copied'));
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: Text(tr('copy')),
                      ),
                      TextButton.icon(
                        onPressed: () => Core.share(url),
                        icon: const Icon(Icons.share_rounded, size: 18),
                        label: Text(tr('share')),
                      ),
                      TextButton.icon(
                        onPressed: () => showQrDialog(context, tr('sub_links'), url),
                        icon: const Icon(Icons.qr_code_2_rounded, size: 18),
                        label: const Text('QR'),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: tr('delete'),
                        onPressed: () async {
                          store.subs.remove(url);
                          store.nodes.removeWhere((n) => n.src == 'sub');
                          if (store.selected >= store.nodes.length) store.selected = 0;
                          await store.save();
                          set(() {});
                          if (mounted) setState(() {});
                          if (store.subs.isNotEmpty) _refreshSubs(silent: true);
                        },
                        icon: Icon(Icons.delete_outline_rounded, color: Pal.red),
                      ),
                    ]),
                  ]),
                ),
            ]),
          ),
        ),
      ),
    );
  }

  // ---------- UI ----------

  String _fmtDur(Duration d) {
    final h = d.inHours;
    return '${two(h)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  Future<void> _pasteAdd() async {
    final d = await Clipboard.getData('text/plain');
    final t = d?.text?.trim() ?? '';
    if (t.isEmpty) {
      _toast(tr('error'));
      return;
    }
    store.lastClip = t;
    _addText(t);
  }

  void _addSheet() {
    final c = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Pal.dialog,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(26))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tr('add_config'), style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Pal.t1)),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                maxLines: 5,
                minLines: 3,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  hintText: tr('add_hint'),
                  filled: true,
                  fillColor: Pal.card,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await Clipboard.getData('text/plain');
                    if (d?.text != null) c.text = d!.text!;
                  },
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: Text(tr('paste')),
                ),
                if (!Platform.isWindows) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _scanQr();
                    },
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                    label: Text(tr('scan_qr')),
                  ),
                ],
                const Spacer(),
                FilledButton.icon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _addText(c.text);
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('add')),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _scanQr() async {
    final v = await Navigator.push<String>(context, MaterialPageRoute(builder: (_) => const ScanPage()));
    if (v != null && v.isNotEmpty) _addText(v);
  }

  void _goTab(int i) {
    if (i == tab) return;
    HapticFeedback.selectionClick();
    final prev = tab;
    setState(() => tab = i);
    if (prev == 3) _markAllRead(); // everything shown in the inbox counts as read once you leave it
    if (prev == 4) _maybeRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) {
      return Scaffold(
        body: Backdrop(
          child: SafeArea(
            bottom: false,
            child: !ready
                ? const Center(child: CircularProgressIndicator())
                : Stack(children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(scale: Tween<double>(begin: 0.96, end: 1.0).animate(anim), child: child),
                      ),
                      child: KeyedSubtree(key: ValueKey(tab), child: _tabBody()),
                    ),
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 10 + MediaQuery.of(context).padding.bottom,
                      child: _navBar(),
                    ),
                  ]),
          ),
        ),
      );
    });
  }

  Widget _tabBody() {
    switch (tab) {
      case 1:
        return _tabServers();
      case 2:
        return AppsPage(store: store, embedded: true, onChanged: () {
          if (mounted) setState(() {});
        });
      case 3:
        return InboxPage(store: store, embedded: true, onChanged: () {
          if (mounted) setState(() {});
        });
      case 4:
        return SettingsPage(store: store, embedded: true);
      default:
        return _tabHome();
    }
  }

  /// Floating glass tab bar (like Telegram): a highlight capsule slides to the chosen tab.
  Widget _navBar() {
    final items = <(IconData, String)>[
      (Icons.shield_rounded, tr('tab_home')),
      (Icons.public_rounded, tr('tab_servers')),
      (Icons.apps_rounded, tr('tab_apps')),
      (Icons.notifications_rounded, tr('tab_inbox')),
      (Icons.settings_rounded, tr('tab_settings')),
    ];
    final unread = _unread;
    final n = items.length;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(32),
        boxShadow: [BoxShadow(color: Pal.shadow, blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            height: 68,
            decoration: BoxDecoration(
              color: Pal.navBg,
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: Pal.cardBorder),
            ),
            child: Stack(children: [
              AnimatedAlign(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeOutCubic,
                alignment: AlignmentDirectional(-1 + 2 * tab / (n - 1), 0),
                child: FractionallySizedBox(
                  widthFactor: 1 / n,
                  heightFactor: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Pal.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(26),
                      ),
                    ),
                  ),
                ),
              ),
              Row(children: [
                for (var i = 0; i < n; i++)
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _goTab(i),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        AnimatedScale(
                          scale: i == tab ? 1.18 : 1.0,
                          duration: const Duration(milliseconds: 260),
                          curve: Curves.easeOutBack,
                          child: Badge(
                            isLabelVisible: (i == 3 && unread > 0) || (i == 2 && store.perAppMode != 'all'),
                            label: i == 3 ? Text('$unread') : null,
                            smallSize: 9,
                            child: Icon(items[i].$1, size: 24, color: i == tab ? Pal.accent : Pal.t3),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items[i].$2,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: i == tab ? FontWeight.w800 : FontWeight.w500,
                            color: i == tab ? Pal.accent : Pal.t3,
                          ),
                        ),
                      ]),
                    ),
                  ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  // ----- tab 0: home -----

  Widget _tabHome() {
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
    final labelColor = running ? Pal.green : (starting || busyPhase ? Pal.orange : Pal.t2);
    return Column(children: [
      _topBar(),
      if (_warnVisible) _warnBanner(),
      if (updCand != null) _updBanner(),
      if (annCand != null) _annBanner(),
      if (clipCand != null) _clipBanner(),
      Expanded(
        child: LayoutBuilder(
          builder: (context, c) => SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 100),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: math.max(0.0, c.maxHeight - 100)),
              child: Center(child: _hero(label, labelColor, busyPhase)),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _hero(String label, Color labelColor, bool busyPhase) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 200,
        height: 200,
        child: FittedBox(
          child: PowerButton(
            on: running,
            loading: starting || busyPhase,
            onTap: () {
              HapticFeedback.mediumImpact();
              _toggle();
            },
          ),
        ),
      ),
      const SizedBox(height: 6),
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: Text(label,
            key: ValueKey(label),
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: labelColor)),
      ),
      if (running && connectedAt != null)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
              _fmtDur(DateTime.now().difference(connectedAt!)),
              style: TextStyle(fontSize: 15, color: Pal.t3, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ),
      const SizedBox(height: 12),
      _modeToggle(),
      const SizedBox(height: 12),
      if (running) _speedCard(),
      if (running) const SizedBox(height: 10),
      _serverCard(),
      if (store.info != null) const SizedBox(height: 10),
      if (store.info != null) _usageCard(),
    ]);
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
      child: Row(children: [
        const Logo(size: 34),
        const SizedBox(width: 10),
        Text(kAppName, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: Pal.t1)),
        const Spacer(),
        IconButton(
          tooltip: tr('theme'),
          onPressed: () => saveTheme(Pal.dark ? 'light' : 'dark'),
          icon: Icon(Pal.dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded, size: 24),
        ),
      ]),
    );
  }

  Widget _clipBanner() => _banner(
        icon: Icons.content_paste_go_rounded,
        text: tr('clip_found'),
        action: tr('add'),
        onAction: () async {
          final t = clipCand!;
          store.lastClip = t;
          setState(() => clipCand = null);
          await store.save();
          _addText(t);
        },
        onClose: () async {
          store.lastClip = clipCand!;
          setState(() => clipCand = null);
          await store.save();
        },
      );

  Widget _updBanner() => _banner(
        icon: Icons.system_update_rounded,
        text: '${tr('update_available')}  (${updCand!.tag})',
        action: tr('update_now'),
        onAction: () async {
          final u = updCand;
          setState(() => updCand = null);
          await Navigator.push(context, MaterialPageRoute(builder: (_) => UpdatePage(info: u)));
        },
        onClose: () => setState(() => updCand = null),
      );

  Widget _serverCard() {
    Node? n;
    if (store.nodes.isNotEmpty && store.selected < store.nodes.length) n = store.nodes[store.selected];
    final d = n?.delay;
    return SizedBox(
      width: 300,
      child: GestureDetector(
        onTap: () => _goTab(1),
        child: Glass(
          radius: 22,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: n == null
              ? Row(children: [
                  Icon(Icons.add_circle_outline_rounded, color: Pal.cyan),
                  const SizedBox(width: 10),
                  Expanded(child: Text(tr('no_servers'), style: TextStyle(color: Pal.t2))),
                  Icon(Icons.chevron_right_rounded, color: Pal.t3),
                ])
              : Row(children: [
                  Container(
                    width: 42,
                    height: 42,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: Pal.card, borderRadius: BorderRadius.circular(12)),
                    child: n.flag != null ? Text(n.flag!, style: const TextStyle(fontSize: 24)) : Icon(Icons.public_rounded, color: Pal.t3),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(n.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: Pal.t1)),
                      Text(n.subtitle,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Pal.t4)),
                    ]),
                  ),
                  if (d != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(color: pingColor(d).withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text('${d}ms', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: pingColor(d))),
                      ),
                    ),
                  Icon(Icons.chevron_right_rounded, color: Pal.t3),
                ]),
        ),
      ),
    );
  }

  Widget _usageCard() {
    final i = store.info!;
    final total = i.total;
    final exp = i.expire > 0 ? fmtDate(DateTime.fromMillisecondsSinceEpoch(i.expire * 1000)) : null;
    return SizedBox(
      width: 300,
      child: Glass(
        radius: 22,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.data_usage_rounded, size: 18, color: Pal.accent),
            const SizedBox(width: 6),
            Expanded(child: Text(tr('data_usage'), style: TextStyle(fontSize: 13, color: Pal.t3))),
            if (exp != null) Text('${tr('expires')}: $exp', style: TextStyle(fontSize: 12, color: Pal.t3)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              minHeight: 8,
              value: total > 0 ? (i.used / total).clamp(0.0, 1.0) : 0.0,
              backgroundColor: Pal.card,
              color: Pal.accent,
            ),
          ),
          const SizedBox(height: 6),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text('${fmtBytes(i.used)} / ${total > 0 ? fmtBytes(total) : '∞'}',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Pal.t1)),
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: _contactSupport,
              icon: const Icon(Icons.support_agent_rounded, size: 18),
              label: Text(tr('warn_charge')),
            ),
          ),
        ]),
      ),
    );
  }

  // ----- tab 1: servers / subscription -----

  Widget _tabServers() {
    return RefreshIndicator(
      onRefresh: () => _refreshSubs(),
      child: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
      SliverToBoxAdapter(
        child: Column(children: [
          const SizedBox(height: 10),
          _sheetHeader(),
          if (busy) const LinearProgressIndicator(minHeight: 2),
          _infoBar(),
        ]),
      ),
      if (store.nodes.isEmpty)
        SliverToBoxAdapter(child: _emptyState())
      else
        SliverList.builder(itemCount: store.nodes.length, itemBuilder: (_, i) => _nodeCard(i)),
      const SliverToBoxAdapter(child: SizedBox(height: 110)),
    ]));
  }

  Widget _banner({required IconData icon, required String text, required String action, required VoidCallback onAction, required VoidCallback onClose, Color? tint}) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      decoration: BoxDecoration(
        color: (tint ?? Pal.accent).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Pal.cardBorder),
      ),
      child: Row(children: [
        Icon(icon, color: tint ?? Pal.cyan),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14.5, color: Pal.t1)),
        ),
        TextButton(onPressed: onAction, child: Text(action)),
        IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close_rounded, size: 20), onPressed: onClose),
      ]),
    );
  }

  Widget _annBanner() {
    final a = annCand!;
    return _banner(
      icon: Icons.campaign_rounded,
      text: a.title.isEmpty ? tr('new_message') : a.title,
      action: tr('view'),
      onAction: () {
        setState(() => annCand = null);
        _goTab(3);
      },
      onClose: _markAllRead,
    );
  }

  Widget _speedCard() {
    Widget item(IconData ic, Color c, String txt) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(ic, size: 20, color: c),
          const SizedBox(width: 4),
          Text(txt,
              style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700, color: Pal.t1, fontFeatures: const [FontFeature.tabularFigures()])),
        ]);
    return SizedBox(
      width: 300,
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              item(Icons.arrow_downward_rounded, Pal.green, fmtRate(traffic.down)),
              item(Icons.arrow_upward_rounded, Pal.cyan, fmtRate(traffic.up)),
            ]),
            const SizedBox(height: 6),
            SizedBox(height: 40, width: double.infinity, child: Sparkline(downHist, Pal.green)),
            const SizedBox(height: 2),
            Text('${tr('session')}: ${fmtBytes(traffic.totDown + traffic.totUp)}',
                style: TextStyle(fontSize: 12.5, color: Pal.t3)),
          ]),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 8),
      child: Column(children: [
        Container(
          width: 76,
          height: 76,
          decoration: BoxDecoration(shape: BoxShape.circle, color: Pal.accent.withValues(alpha: 0.12)),
          child: Icon(Icons.cloud_download_rounded, size: 36, color: Pal.accent),
        ),
        const SizedBox(height: 14),
        Text(tr('no_config'), textAlign: TextAlign.center, style: TextStyle(color: Pal.t3, height: 1.5)),
        const SizedBox(height: 16),
        FilledButton.icon(onPressed: _addSheet, icon: const Icon(Icons.add_rounded), label: Text(tr('add_config'))),
        const SizedBox(height: 4),
        if (!Platform.isWindows)
          TextButton.icon(
            onPressed: _scanQr,
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
            label: Text(tr('scan_qr')),
          ),
        TextButton.icon(
          onPressed: _pasteAdd,
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: Text(tr('paste_add')),
        ),
      ]),
    );
  }

  Widget _sheetHeader() {
    final upd = store.updatedMs == 0 ? null : DateTime.fromMillisecondsSinceEpoch(store.updatedMs);
    final title = store.subTitle.isNotEmpty ? store.subTitle : tr('subscription');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: Pal.t1)),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                    color: Pal.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: Pal.cardBorder)),
                child: Text('${store.nodes.length}', style: TextStyle(fontSize: 12.5, color: Pal.t2)),
              ),
            ]),
            if (upd != null)
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(formatDateTime(upd),
                    style: TextStyle(fontSize: 12, color: Pal.t4)),
              ),
          ]),
        ),
        IconButton(tooltip: tr('add_config'), onPressed: _addSheet, icon: Icon(Icons.add_circle_outline_rounded, color: Pal.cyan)),
        IconButton(
          tooltip: tr('update_sub'),
          onPressed: busy ? null : () => _refreshSubs(),
          icon: Icon(Icons.sync_rounded, color: Pal.cyan),
        ),
        IconButton(
          tooltip: tr('test_ping'),
          onPressed: busy ? null : _ping,
          icon: Icon(Icons.speed_rounded, color: Pal.cyan),
        ),
        PopupMenuButton<String>(
          icon: Icon(Icons.more_horiz_rounded, color: Pal.cyan),
          onSelected: (v) async {
            if (v == 'links') {
              _linksSheet();
            } else if (v == 'clear') {
              store.nodes = [];
              store.subs = [];
              store.selected = 0;
              store.info = null;
              store.subTitle = '';
              store.updatedMs = 0;
              await store.save();
              if (mounted) setState(() {});
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(value: 'links', child: Text(tr('sub_links'))),
            PopupMenuItem(value: 'clear', child: Text(tr('delete_all'))),
          ],
        ),
      ]),
    );
  }

  Widget _infoBar() {
    final i = store.info;
    if (i == null) return const SizedBox(height: 6);
    final used = i.used;
    final total = i.total;
    final exp = i.expire > 0 ? fmtDate(DateTime.fromMillisecondsSinceEpoch(i.expire * 1000)) : null;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Pal.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Pal.cardBorder),
      ),
      child: Row(children: [
        Icon(Icons.data_usage_rounded, color: Pal.accent, size: 22),
        const SizedBox(width: 10),
        Expanded(
          child: Stack(alignment: Alignment.center, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                minHeight: 22,
                value: total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0,
                backgroundColor: Pal.card,
                color: Pal.accent.withValues(alpha: 0.4),
              ),
            ),
            Directionality(
              textDirection: TextDirection.ltr,
              child: Text('${fmtBytes(used)} / ${total > 0 ? fmtBytes(total) : '∞'}',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Pal.t1)),
            ),
          ]),
        ),
        if (exp != null) ...[
          const SizedBox(width: 10),
          Text('${tr('expires')}: $exp', style: TextStyle(fontSize: 12.5, color: Pal.t2)),
        ],
        IconButton(
          visualDensity: VisualDensity.compact,
          onPressed: () => openTelegram(kChannelUser),
          icon: Icon(Icons.send_rounded, color: Pal.cyan, size: 22),
        ),
      ]),
    );
  }

  Widget _nodeCard(int i) {
    final n = store.nodes[i];
    final sel = i == store.selected;
    final d = n.delay;
    final pingText = d != null ? '${d}ms' : (n.tested ? 'n/a' : '');
    final pc = pingColor(d);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 3, 12, 3),
      decoration: BoxDecoration(
        color: sel ? Pal.accent.withValues(alpha: 0.14) : Pal.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: sel ? Pal.accent.withValues(alpha: 0.8) : Pal.cardBorder, width: sel ? 1.4 : 1),
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
                decoration: BoxDecoration(color: Pal.card, borderRadius: BorderRadius.circular(12)),
                child: n.flag != null ? Text(n.flag!, style: const TextStyle(fontSize: 24)) : Icon(Icons.public_rounded, color: Pal.t3),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    if (sel && running)
                      Container(
                        width: 8,
                        height: 8,
                        margin: const EdgeInsetsDirectional.only(end: 6),
                        decoration: BoxDecoration(color: Pal.green, shape: BoxShape.circle),
                      ),
                    Flexible(
                      child: Text(n.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Pal.t1)),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(n.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Pal.t4)),
                ]),
              ),
              if (pingText.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(color: pc.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(pingText, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: pc)),
                  ),
                ),
              IconButton(
                visualDensity: VisualDensity.compact,
                onPressed: () => _nodeDetails(i),
                icon: Icon(Icons.more_vert_rounded, color: Pal.t4, size: 20),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
