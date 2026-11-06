import 'dart:convert';

/// Where the app looks for messages to the customers. Edit announcements.json in the
/// GitHub repo (see README) to publish a new message.
const kAnnounceUrls = [
  'https://raw.githubusercontent.com/mojyrayzor-prog/dastras-ng/main/announcements.json',
  'https://cdn.jsdelivr.net/gh/mojyrayzor-prog/dastras-ng@main/announcements.json',
];

class Announcement {
  final int id;
  final String title, body, url, date;
  const Announcement(this.id, this.title, this.body, this.url, this.date);
}

List<Announcement> parseAnnouncements(String raw) {
  try {
    final list = jsonDecode(raw) as List;
    final out = <Announcement>[];
    for (final e in list) {
      if (e is! Map) continue;
      final id = e['id'];
      if (id is! int) continue;
      out.add(Announcement(
        id,
        (e['title'] ?? '').toString(),
        (e['body'] ?? '').toString(),
        (e['url'] ?? '').toString(),
        (e['date'] ?? '').toString(),
      ));
    }
    out.sort((a, b) => b.id.compareTo(a.id));
    return out;
  } catch (_) {
    return [];
  }
}
