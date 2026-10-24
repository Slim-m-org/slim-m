// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Readers for the module platform fields a manifest and an installed module
/// carry, per `docs/decisions/0091-module-platform-phase-1-contracts.md`.
library;

/// The event kinds a module subscribes to, from names or `{event: name}`.
List<String> dockSubscriptions(Object? json) {
  if (json is! List) return const [];
  return [
    for (final entry in json)
      if (entry is String)
        entry
      else if (entry is Map && entry['event'] is String)
        entry['event'] as String,
  ];
}

/// The size cap in MB of the data store a module declares, or null when it
/// declares none. The host's default applies when `max_mb` is left out.
int? dockDataMaxMb(Object? json) {
  if (json is! Map) return null;
  final mb = json['max_mb'];
  return mb is int ? mb : 8;
}

/// Whether a module's `settings` array declares at least one setting.
bool dockDeclaresSettings(Object? json) => json is List && json.isNotEmpty;

/// One column of a module's data table: its type and the index flags it asks for.
class DockDataColumn {
  const DockDataColumn({
    required this.name,
    this.type = '',
    this.unique = false,
    this.index = false,
  });

  final String name;
  final String type;
  final bool unique;
  final bool index;
}

/// A module's declared data store: the size cap and its tables with columns.
class DockDataSchema {
  const DockDataSchema({required this.maxMb, this.tables = const {}});

  final int maxMb;

  /// Columns by name, per table name.
  final Map<String, Map<String, DockDataColumn>> tables;

  /// Whether [wanted] asks for no more room than this: not a larger cap, no
  /// new table or column, and no index flag this one lacks. Mirrors the
  /// server's `data_not_widened`, which drops the approval otherwise.
  bool covers(DockDataSchema wanted) {
    if (wanted.maxMb > maxMb) return false;
    for (final table in wanted.tables.entries) {
      final had = tables[table.key];
      if (had == null) return false;
      for (final column in table.value.values) {
        final old = had[column.name];
        if (old == null) return false;
        if ((column.unique && !old.unique) || (column.index && !old.index)) {
          return false;
        }
      }
    }
    return true;
  }
}

/// The data store a module declares, or null when it declares none.
DockDataSchema? dockDataSchema(Object? json) {
  final maxMb = dockDataMaxMb(json);
  if (maxMb == null || json is! Map) return null;
  final tables = <String, Map<String, DockDataColumn>>{};
  final rawTables = json['tables'];
  for (final table in rawTables is List ? rawTables : const []) {
    if (table is! Map || table['name'] is! String) continue;
    final columns = <String, DockDataColumn>{};
    final rawColumns = table['columns'];
    for (final column in rawColumns is List ? rawColumns : const []) {
      if (column is! Map || column['name'] is! String) continue;
      final name = column['name'] as String;
      columns[name] = DockDataColumn(
        name: name,
        type: column['type'] is String ? column['type'] as String : '',
        unique: column['unique'] == true,
        index: column['index'] == true,
      );
    }
    tables[table['name'] as String] = columns;
  }
  return DockDataSchema(maxMb: maxMb, tables: tables);
}
