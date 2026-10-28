// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Dock module's changelog and the version ordering it relies on.
library;

/// One release in a module's changelog: the version and its one-line changes.
class DockChangelogEntry {
  const DockChangelogEntry({required this.version, required this.changes});

  final String version;
  final List<String> changes;
}

/// Newest first, as published. Anything malformed is dropped, never thrown on,
/// because a bad changelog must not stop the module opening.
List<DockChangelogEntry> dockChangelog(Object? json) {
  if (json is! List) return const [];
  return [
    for (final item in json)
      if (item is Map && item['version'] is String && item['changes'] is List)
        DockChangelogEntry(
          version: item['version'] as String,
          changes: [
            for (final c in item['changes'] as List)
              if (c is String) c,
          ],
        ),
  ];
}

List<DockChangelogEntry> newestDockChangelogFirst(
    List<DockChangelogEntry> entries) {
  bool numeric(DockChangelogEntry e) =>
      compareDockVersions(e.version, e.version) != null;
  final nums = entries.where(numeric).toList()
    ..sort((a, b) => compareDockVersions(b.version, a.version)!);
  return [...nums, ...entries.where((e) => !numeric(e))];
}

/// Dot-separated integer parts compared left to right (missing parts are 0);
/// null when either side is not purely numeric.
int? compareDockVersions(String a, String b) {
  final pa = _versionParts(a);
  final pb = _versionParts(b);
  if (pa == null || pb == null) return null;
  final length = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < length; i++) {
    final x = _partAt(pa, i);
    final y = _partAt(pb, i);
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

List<int>? _versionParts(String v) {
  final out = <int>[];
  for (final p in v.split('.')) {
    final n = int.tryParse(p);
    if (n == null) return null;
    out.add(n);
  }
  return out;
}

int _partAt(List<int> parts, int i) => i < parts.length ? parts[i] : 0;
