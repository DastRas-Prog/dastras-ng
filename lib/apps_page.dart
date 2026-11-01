import 'package:flutter/material.dart';

import 'core.dart';
import 'lang.dart';
import 'models.dart';
import 'theme.dart';

class AppsPage extends StatefulWidget {
  final Store store;
  const AppsPage({super.key, required this.store});
  @override
  State<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends State<AppsPage> {
  List<AppInfo>? apps;
  String q = '';
  late String mode;
  late Set<String> sel;

  @override
  void initState() {
    super.initState();
    mode = widget.store.perAppMode;
    sel = {...widget.store.perAppList};
    _load();
  }

  Future<void> _load() async {
    try {
      apps = await Core.apps();
    } catch (_) {
      apps = [];
    }
    if (mounted) setState(() {});
  }

  Future<void> _save() async {
    widget.store.perAppMode = mode;
    widget.store.perAppList = sel;
    await widget.store.save();
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) {
      final list = (apps ?? [])
          .where((a) => q.isEmpty || a.name.toLowerCase().contains(q.toLowerCase()) || a.pkg.contains(q))
          .toList();
      final enabled = mode != 'all';
      return Scaffold(
        body: Backdrop(
          child: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                child: Row(children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Text(tr('per_app'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (sel.isNotEmpty)
                    Text('${sel.length} ${tr('apps_selected')}', style: const TextStyle(color: Colors.white60)),
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
                    style: const TextStyle(fontSize: 12.5, color: Colors.white54),
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
                    fillColor: kGlass,
                    contentPadding: const EdgeInsets.symmetric(vertical: 0),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: apps == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final a = list[i];
                          final on = sel.contains(a.pkg);
                          return CheckboxListTile(
                            value: on,
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
                                style: const TextStyle(fontSize: 11.5, color: Colors.white38)),
                          );
                        },
                      ),
              ),
            ]),
          ),
        ),
      );
    });
  }
}
