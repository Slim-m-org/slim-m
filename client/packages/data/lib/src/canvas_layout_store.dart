// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A viewer's own canvas layouts, kept on this device per channel.
/// Decision 0082.
library;

import 'package:drift/drift.dart';

import 'database.dart';

/// Most channels whose layout is kept; the least recently changed go first.
const int canvasLayoutsCap = 40;

class CanvasLayoutStore {
  CanvasLayoutStore(this._db);

  final SlimmDatabase _db;

  Future<String?> load(String channelId) async {
    final row = await (_db.select(_db.canvasPersonalLayouts)
          ..where((l) => l.channelId.equals(channelId)))
        .getSingleOrNull();
    return row?.layout;
  }

  /// Keeps [layout] for [channelId], then drops rows for channels this account
  /// no longer has and the oldest beyond [canvasLayoutsCap].
  Future<void> save(String channelId, String layout, {required int now}) =>
      _db.transaction(() async {
        await _db.into(_db.canvasPersonalLayouts).insertOnConflictUpdate(
              CanvasPersonalLayoutsCompanion.insert(
                channelId: channelId,
                layout: layout,
                updatedAt: now,
              ),
            );
        await _prune(keep: channelId);
      });

  Future<void> delete(String channelId) async {
    await (_db.delete(_db.canvasPersonalLayouts)
          ..where((l) => l.channelId.equals(channelId)))
        .go();
  }

  Future<void> _prune({required String keep}) async {
    final known = await (_db.selectOnly(_db.channels)
          ..addColumns([_db.channels.id])
          ..limit(1))
        .get();
    if (known.isNotEmpty) {
      await (_db.delete(_db.canvasPersonalLayouts)
            ..where(
              (l) =>
                  l.channelId.equals(keep).not() &
                  l.channelId.isNotInQuery(
                    _db.selectOnly(_db.channels)..addColumns([_db.channels.id]),
                  ),
            ))
          .go();
    }
    // Ids only, past the cap: the layout blobs themselves never cross the isolate port to prune.
    final layouts = _db.canvasPersonalLayouts;
    final stale = await (_db.selectOnly(layouts)
          ..addColumns([layouts.channelId])
          ..orderBy([OrderingTerm.desc(layouts.updatedAt)])
          ..limit(1 << 30, offset: canvasLayoutsCap))
        .map((row) => row.read(layouts.channelId)!)
        .get();
    for (final id in stale) {
      // A saved row with a stale clock still belongs to the caller.
      if (id != keep) await delete(id);
    }
  }
}
