import 'package:flutter/material.dart';

import 'core.dart';
import 'lang.dart';
import 'models.dart';
import 'pal.dart';
import 'theme.dart';

class AppsPage extends StatefulWidget {
  final Store store;
  final bool embedded;
  final VoidCallback? onChanged;
  const AppsPage({super.key, required this.store, this.embedded = false, this.onChanged});
  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  static List<AppInfo>? _cache; // the icon list is heavy: load it once
  List<AppInfo>? apps;
  String q = '';
  late String mode;
  late Set<String> sel;

  @override
  void initState() {
    super.initState();
    mode = widget.store.perAppMode;
    sel = {...widget.store.perAppList};
    apps = _cache;
    if (apps == null) _load();
  }

  Future<void> _load() async {
    try {
      apps = _cache = await Core.apps();
    } catch (_) {
      apps = [];
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    widget.store.perAppMode = mode;
    widget.store.perAppList = sel;
    await widget.store.save();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) {
      final list = (apps ?? [])
          .where((a) => q.isEmpty || a.name.toLowerCase().contains(q.toLowerCase()) || a.pkg.contains(q))
          .toList();
      list.sort((a, b) {
        final x = sel.contains(a.pkg) ? 0 : 1;
        final y = sel.contains(b.pkg) ? 0 : 1;
        if (x != y) return x - y; // chosen apps float to the top
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      final enabled = mode != 'all';
      final content = Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                child: Row(children: [
                  if (widget.embedded) const SizedBox(width: 16) else IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
                  Text(tr('per_app'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Pal.t1)),
                  const Spacer(),
                  if (sel.isNotEmpty)
                    Text('${sel.length} ${tr('apps_selected')}', style: TextStyle(color: Pal.t3)),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<String>(
                    showSelectedIcon: false,
                    segments: [
                      ButtonSegment(value: 'all', label: Text(tr('per_app_all'), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ButtonSegment(value: 'include', label: Text(tr('per_app_include'), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      ButtonSegment(value: 'exclude', label: Text(tr('per_app_exclude'), maxLines: 1, overflow: TextOverflow.ellipsis)),
                    ],
                    selected: {mode},
                    onSelectionChanged: (v) async {
                      setState(() => mode = v.first);
                      await _save();
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    mode == 'all' ? tr('per_app_note_all') : (mode == 'include' ? tr('per_app_note_include') : ''),
                    style: TextStyle(fontSize: 12.5, color: Pal.t3),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => q = v),
                  decoration: InputDecoration(
                    hintText: tr('search'),
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: Pal.card,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                  ),
                ),
              ),
              Expanded(
                child: apps == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        padding: EdgeInsets.only(bottom: widget.embedded ? 110 : 0),
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final a = list[i];
                          return CheckboxListTile(
                            value: sel.contains(a.pkg),
                            enabled: enabled,
                            onChanged: (v) async {
                              setState(() {
                                if (v == true) {
                                  sel.add(a.pkg);
                                } else {
                                  sel.remove(a.pkg);
                                }
                              });
                              await _save();
                            },
                            secondary: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.memory(a.icon, width: 42, height: 42, gaplessPlayback: true),
                            ),
                            title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(a.pkg,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: Pal.t4)),
                          );
                        },
                      ),
              ),
      ]);
      return widget.embedded ? content : Scaffold(body: Backdrop(child: SafeArea(child: content)));
    });
  }
}
