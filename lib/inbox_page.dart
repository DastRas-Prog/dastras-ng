import 'package:flutter/material.dart';

import 'announce.dart';
import 'lang.dart';
import 'main.dart' show openAny;
import 'models.dart';
import 'pal.dart';
import 'theme.dart';

class InboxPage extends StatelessWidget {
  final Store store;
  final bool embedded;
  final int newerThan; // items with a bigger id get a "New" tag
  const InboxPage({super.key, required this.store, this.embedded = false, this.newerThan = 1 << 30});

  @override
  Widget build(BuildContext context) {
    final items = parseAnnouncements(store.annJson);
    return Tr((context) {
      final content = Column(children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                  child: Row(children: [
                    if (embedded) const SizedBox(width: 16) else IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context)),
                    Text(tr('inbox'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Pal.t1)),
                  ]),
                ),
                Expanded(
                  child: items.isEmpty
                      ? Center(child: Text(tr('inbox_empty'), style: TextStyle(color: Pal.t3)))
                      : ListView.builder(
                          padding: EdgeInsets.fromLTRB(16, 8, 16, embedded ? 110 : 24),
                          itemCount: items.length,
                          itemBuilder: (_, i) {
                            final a = items[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Glass(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Icon(Icons.campaign_rounded, color: Pal.cyan),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(a.title.isEmpty ? tr('new_message') : a.title,
                                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Pal.t1)),
                                    ),
                                    if (a.id > newerThan)
                                      Container(
                                        margin: const EdgeInsetsDirectional.only(end: 8),
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
                                  if (a.url.isNotEmpty)
                                    Align(
                                      alignment: AlignmentDirectional.centerEnd,
                                      child: TextButton.icon(
                                        onPressed: () => openAny(a.url),
                                        icon: const Icon(Icons.open_in_new_rounded, size: 18),
                                        label: Text(tr('open_link')),
                                      ),
                                    ),
                                ]),
                              ),
                            );
                          },
                        ),
                ),
      ]);
      return embedded ? content : Scaffold(body: Backdrop(child: SafeArea(child: content)));
    });
  }
}
