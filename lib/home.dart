import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'apps_page.dart';
import 'config.dart';
import 'core.dart';
import 'lang.dart';
import 'main.dart' show kAppName, kChannelUrl, kSupportUrl, openUrl;
import 'models.dart';
import 'service.dart';
import 'theme.dart';

String fmtBytes(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < 4) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i <= 1 ? 0 : 1)}${u[i]}';
}

String two(int n) => n.toString().padLeft(2, '0');
String fmtDate(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';

Color pingColor(int? d) {
  if (d == null) return Colors.white38;
  if (d < 400) return kGreen;
  if (d < 1000) return kOrange;
  return const Color(0xFFFF6B6B);
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final store = Store();
  bool ready = false;
  bool busy = false;
  bool updating = false;
  bool expanded = true;
  String status = 'stopped';
  String? lastShownError;
  Timer? timer;

  bool get running => status == 'running';
  bool get starting => status == 'starting';

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    await store.load();
    status = await Core.status();
    if (!mounted) return;
    setState(() => ready = true);
    timer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
    if (store.subs.isNotEmpty && !running) _refreshSubs(silent: true);
  }

  Future<void> _poll() async {
    final s = await Core.status();
    if (!mounted) return;
    if (s != status) setState(() => status = s);
    if (s.startsWith('error:') && s != lastShownError) {
      lastShownError = s;
      _toast('${tr('error')}: ${s.substring(6)}');
    }
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _toggle() async {
    if (updating) return;
    if (running || starting) {
      await Core.stop();
      return;
    }
    if (store.nodes.isEmpty && store.subs.isEmpty) {
      _toast(tr('need_config'));
      return;
    }
    // Like Hiddify: refresh the subscription before connecting.
    if (store.subs.isNotEmpty) {
      setState(() => updating = true);
      try {
        await _refreshSubs(silent: true).timeout(const Duration(seconds: 12));
      } catch (_) {}
      if (mounted) setState(() => updating = false);
    }
    if (store.nodes.isEmpty) {
      _toast(tr('need_config'));
      return;
    }
    if (store.selected >= store.nodes.length) store.selected = 0;
    lastShownError = null;
    final node = store.nodes[store.selected];
    final res = await Core.start(
      buildConfig(node.ob, store.bypassIran),
      store.perAppMode,
      store.perAppList.toList(),
    );
    if (res == 'denied') _toast(tr('vpn_denied'));
  }

  Future<void> _refreshSubs({bool silent = false}) async {
    if (store.subs.isEmpty) {
      if (!silent) _toast(tr('no_sub'));
      return;
    }
    if (!silent && mounted) setState(() => busy = true);
    try {
      final selKey = store.nodes.isNotEmpty && store.selected < store.nodes.length
          ? store.nodes[store.selected].key
          : null;
      final oldDelays = {for (final n in store.nodes) n.key: n};
      final all = <Node>[];
      SubInfo? info;
      for (final url in store.subs) {
        final r = await fetchSub(url);
        final obs = await convert(r.body);
        for (final o in obs) {
          final n = Node(o, 'sub');
          final old = oldDelays[n.key];
          if (old != null) {
            n.delay = old.delay;
            n.tested = old.tested;
          }
          all.add(n);
        }
        if (r.info != null) info = r.info;
      }
      store.nodes = [...store.nodes.where((n) => n.src != 'sub'), ...all];
      final idx = selKey == null ? -1 : store.nodes.indexWhere((n) => n.key == selKey);
      store.selected = idx >= 0 ? idx : 0;
      store.info = info;
      store.updatedMs = DateTime.now().millisecondsSinceEpoch;
      await store.save();
      if (!silent) _toast('${tr('sub_updated')} (${all.length} ${tr('configs_n')})');
    } catch (e) {
      if (!silent) _toast('${tr('error')}: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _addText(String text) async {
    text = text.trim();
    if (text.isEmpty) return;
    setState(() => busy = true);
    try {
      final isSub = !text.contains('\n') && (text.startsWith('http://') || text.startsWith('https://'));
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
    if (running || starting) {
      _toast(tr('disconnect_first'));
      return;
    }
    if (store.nodes.isEmpty) return;
    setState(() => busy = true);
    try {
      final res = await pingBatch(store.nodes.map((n) => n.ob).toList());
      for (var i = 0; i < store.nodes.length && i < res.length; i++) {
        store.nodes[i].delay = res[i];
        store.nodes[i].tested = true;
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
        store.selected = 0;
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

  void _settings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF151D40),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                leading: const Icon(Icons.language_rounded, color: kCyan),
                title: Text(tr('language')),
                trailing: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(value: 'fa', label: Text('فارسی')),
                    ButtonSegment(value: 'en', label: Text('EN')),
                  ],
                  selected: {langN.value},
                  onSelectionChanged: (v) async {
                    await saveLang(v.first);
                    set(() {});
                  },
                ),
              ),
              SwitchListTile(
                secondary: const Icon(Icons.shield_moon_rounded, color: kCyan),
                title: Text(tr('bypass_iran')),
                value: store.bypassIran,
                onChanged: (v) async {
                  store.bypassIran = v;
                  await store.save();
                  set(() {});
                },
              ),
              ListTile(
                leading: const Icon(Icons.support_agent_rounded, color: kCyan),
                title: Text(tr('support')),
                subtitle: const Text('@xAdministrator'),
                onTap: () => openUrl(kSupportUrl),
              ),
              ListTile(
                leading: const Icon(Icons.send_rounded, color: kCyan),
                title: Text(tr('channel')),
                subtitle: const Text('@dastras'),
                onTap: () => openUrl(kChannelUrl),
              ),
              ListTile(
                leading: const Icon(Icons.info_outline_rounded, color: kCyan),
                title: Text(tr('about')),
                onTap: () {
                  Navigator.pop(ctx);
                  _about();
                },
              ),
            ]),
          ),
        ),
      ),
    );
  }

  void _about() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(kAppName),
        content: Text(tr('about_text')),
        actions: [
          TextButton(onPressed: () => openUrl(kSupportUrl), child: Text(tr('support'))),
          FilledButton(onPressed: () => openUrl(kChannelUrl), child: Text(tr('channel'))),
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
      final label = updating
          ? tr('updating_sub')
          : running
              ? tr('connected')
              : starting
                  ? tr('connecting')
                  : tr('tap_connect');
      final labelColor = running ? kGreen : (starting || updating ? kOrange : Colors.white70);
      return Scaffold(
        body: Backdrop(
          child: SafeArea(
            child: !ready
                ? const Center(child: CircularProgressIndicator())
                : Column(children: [
                    _topBar(),
                    Expanded(
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            PowerButton(on: running, loading: starting || updating, onTap: _toggle),
                            const SizedBox(height: 14),
                            Text(label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: labelColor)),
                            const SizedBox(height: 12),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(children: [
        const Logo(size: 38),
        const SizedBox(width: 10),
        const Text(kAppName, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        const Spacer(),
        IconButton(
          tooltip: tr('add_config'),
          onPressed: _addDialog,
          icon: const Icon(Icons.add_circle_outline_rounded, size: 28),
        ),
        IconButton(
          tooltip: tr('per_app'),
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => AppsPage(store: store)),
          ),
          icon: Badge(
            isLabelVisible: store.perAppMode != 'all',
            smallSize: 9,
            child: const Icon(Icons.apps_rounded, size: 28),
          ),
        ),
        IconButton(
          tooltip: tr('settings'),
          onPressed: _settings,
          icon: const Icon(Icons.settings_rounded, size: 28),
        ),
      ]),
    );
  }

  Widget _selectedChip() {
    Node? n;
    if (store.nodes.isNotEmpty && store.selected < store.nodes.length) n = store.nodes[store.selected];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: BoxDecoration(
        color: kGlass,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: kGlassBorder),
      ),
      child: n == null
          ? Text(tr('no_servers'), style: const TextStyle(color: Colors.white54))
          : Row(mainAxisSize: MainAxisSize.min, children: [
              Text(n.flag ?? '🌐', style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 190),
                child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
              ),
              if (n.delay != null) ...[
                const SizedBox(width: 10),
                Text('${n.delay}ms', style: TextStyle(fontSize: 14, color: pingColor(n.delay))),
              ],
            ]),
    );
  }

  Widget _sheet(double h) {
    return Container(
      height: expanded ? h * 0.46 : null,
      decoration: BoxDecoration(
        color: const Color(0xCC0F1736),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: const Border(top: BorderSide(color: kGlassBorder)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 4, 6),
      child: Row(children: [
        IconButton(
          onPressed: () => setState(() => expanded = !expanded),
          icon: AnimatedRotation(
            turns: expanded ? 0 : -0.5,
            duration: const Duration(milliseconds: 200),
            child: const Icon(Icons.keyboard_arrow_down_rounded, size: 32, color: kCyan),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('subscription'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            if (upd != null)
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text('${fmtDate(upd)} ${two(upd.hour)}:${two(upd.minute)}',
                    style: const TextStyle(fontSize: 12.5, color: Colors.white38)),
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
      color: const Color(0x1A5B8CFF),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        const Icon(Icons.info_outline_rounded, color: kAccent),
        const SizedBox(width: 10),
        if (i != null)
          Expanded(
            child: Stack(alignment: Alignment.center, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  minHeight: 28,
                  value: total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0,
                  backgroundColor: const Color(0x14FFFFFF),
                  color: const Color(0x555B8CFF),
                ),
              ),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text('${fmtBytes(used)}/${total > 0 ? fmtBytes(total) : '∞'}',
                    style: const TextStyle(fontSize: 14)),
              ),
            ]),
          )
        else
          const Expanded(child: SizedBox()),
        if (exp != null) ...[
          const SizedBox(width: 12),
          Text('${tr('expires')}: $exp', style: const TextStyle(fontSize: 13)),
        ],
        IconButton(
          onPressed: () => openUrl(kChannelUrl),
          icon: const Icon(Icons.send_rounded, color: kCyan),
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
      padding: EdgeInsets.zero,
      itemCount: store.nodes.length,
      itemBuilder: (_, i) {
        final n = store.nodes[i];
        final sel = i == store.selected;
        final d = n.delay;
        final pingText = d != null ? '${d}ms' : (n.tested ? 'n/a' : '');
        return Material(
          color: sel ? const Color(0x1F5B8CFF) : Colors.transparent,
          child: InkWell(
            onTap: () async {
              store.selected = i;
              await store.save();
              setState(() {});
            },
            child: Row(children: [
              Container(width: 4, height: 70, color: sel ? kAccent : Colors.transparent),
              const SizedBox(width: 12),
              Container(
                width: 46,
                height: 46,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kGlass,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kGlassBorder),
                ),
                child: n.flag != null
                    ? Text(n.flag!, style: const TextStyle(fontSize: 26))
                    : const Icon(Icons.public_rounded, color: Colors.white54),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(n.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w500)),
                    Text(n.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5, color: Colors.white38)),
                  ],
                ),
              ),
              Directionality(
                textDirection: TextDirection.ltr,
                child: Text(pingText, style: TextStyle(fontSize: 16, color: pingColor(d))),
              ),
              IconButton(
                onPressed: () => _nodeDetails(i),
                icon: const Icon(Icons.chevron_right_rounded, color: Colors.white38),
              ),
            ]),
          ),
        );
      },
    );
  }
}
