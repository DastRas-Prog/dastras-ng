import 'package:flutter/material.dart';

import 'announce.dart';
import 'lang.dart';
import 'main.dart' show openAny;
import 'models.dart';
import 'pal.dart';
import 'theme.dart';
import 'update.dart';

class InboxPage extends StatefulWidget {
  final Store store;
  final bool embedded;
  final VoidCallback? onChanged;
  const InboxPage({super.key, required this.store, this.embedded = false, this.onChanged});
  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  Store get s => widget.store;

  List<Announcement> get _items =>
      allMessages(s.annJson, s.sysJson).where((a) => !s.annDeleted.contains(a.id)).toList();

  Future<void> _commit() async {
    await s.save();
    if (mounted) setState(() {});
    widget.onChanged?.call();
  }

  Future<void> _delete(Announcement a) async {
    s.annDeleted.add(a.id);
    s.annReadIds.add(a.id);
    await _commit();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(tr('msg_deleted')),
        action: SnackBarAction(
          label: tr('undo'),
          onPressed: () async {
            s.annDeleted.remove(a.id);
            await _commit();
          },
        ),
      ));
  }

  Future<void> _deleteAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(tr('delete_all_confirm')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (ok != true) return;
    for (final a in _items) {
      s.annDeleted.add(a.id);
    }
    await _commit();
  }

  Future<void> _markAll() async {
    for (final a in _items) {
      s.annReadIds.add(a.id);
    }
    await _commit();
  }

  Future<void> _markRead(Announcement a) async {
    if (s.annReadIds.contains(a.id)) return;
    s.annReadIds.add(a.id);
    await _commit();
  }

  @override
  Widget build(BuildContext context) {
    return Tr((context) {
      final items = _items;
      final content = Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 8, 0),
          child: Row(children: [
            if (widget.embedded) const SizedBox(width: 16) else IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
            Expanded(child: Text(tr('inbox'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Pal.t1))),
            if (items.isNotEmpty) ...[
              IconButton(tooltip: tr('mark_all_read'), onPressed: _markAll, icon: Icon(Icons.done_all_rounded, color: Pal.cyan)),
              IconButton(tooltip: tr('delete_all_msgs'), onPressed: _deleteAll, icon: Icon(Icons.delete_sweep_rounded, color: Pal.red)),
            ],
          ]),
        ),
        Expanded(
          child: items.isEmpty
              ? Center(child: Text(tr('inbox_empty'), style: TextStyle(color: Pal.t3)))
              : ListView.builder(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, widget.embedded ? 110 : 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final a = items[i];
                    final read = s.annReadIds.contains(a.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: GestureDetector(
                        onTap: () => _markRead(a),
                        child: Glass(
                          color: read ? null : Pal.accent.withValues(alpha: 0.10),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Icon(Icons.campaign_rounded, color: read ? Pal.t3 : Pal.cyan),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(a.title.isEmpty ? tr('new_message') : a.title,
                                    style: TextStyle(
                                        fontSize: 17,
                                        fontWeight: read ? FontWeight.w500 : FontWeight.w800,
                                        color: Pal.t1)),
                              ),
                              if (!read)
                                Container(
                                  margin: const EdgeInsetsDirectional.only(end: 6),
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(color: Pal.green.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(10)),
                                  child: Text(tr('new_tag'), style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: Pal.green)),
                                ),
                              if (a.date.isNotEmpty)
                                Directionality(
                                  textDirection: TextDirection.ltr,
                                  child: Text(a.date, style: TextStyle(fontSize: 12, color: Pal.t4)),
                                ),
                            ]),
                            if (a.body.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text(a.body, style: TextStyle(fontSize: 14.5, height: 1.5, color: Pal.t2)),
                            ],
                            const SizedBox(height: 4),
                            Row(children: [
                              Icon(read ? Icons.done_all_rounded : Icons.check_rounded, size: 18, color: read ? Pal.green : Pal.t4),
                              const SizedBox(width: 4),
                              Text(read ? tr('read') : tr('new_tag'), style: TextStyle(fontSize: 12, color: read ? Pal.green : Pal.t4)),
                              const Spacer(),
                              if (a.url.isNotEmpty)
                                TextButton.icon(
                                  onPressed: () {
                                    _markRead(a);
                                    if (a.url == kUpdateUrl) {
                                      Navigator.push(context, MaterialPageRoute(builder: (_) => const UpdatePage()));
                                    } else {
                                      openAny(a.url);
                                    }
                                  },
                                  icon: Icon(a.url == kUpdateUrl ? Icons.system_update_rounded : Icons.open_in_new_rounded, size: 18),
                                  label: Text(a.url == kUpdateUrl ? tr('update_now') : tr('open_link')),
                                ),
                              IconButton(
                                tooltip: tr('delete'),
                                visualDensity: VisualDensity.compact,
                                onPressed: () => _delete(a),
                                icon: Icon(Icons.delete_outline_rounded, color: Pal.red, size: 22),
                              ),
                            ]),
                          ]),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ]);
      return widget.embedded ? content : Scaffold(body: Backdrop(child: SafeArea(child: content)));
    });
  }
}
