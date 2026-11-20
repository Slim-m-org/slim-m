// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Channel category reads and writes, split out of `message_store.dart` for
/// the file budget. A category is not a channel and is replaced on its own
/// path here, never through [MessageStore.replaceChannels] - see
/// docs/decisions/0006-channel-categories.md.
library;

import 'package:drift/drift.dart';
import 'package:slimm_api/api.dart' as api;

import 'database.dart';
import 'message_store.dart';

extension CategoryStore on MessageStore {
  /// Watches every live category by position then id; a position orders
  /// siblings only, so the rail arranges the tree itself (decision 0120).
  Stream<List<ChannelCategoryRow>> watchCategories() =>
      _ordered(db.select(db.channelCategories)).watch();

  /// [watchCategories]'s own snapshot, for a caller that wants today's list
  /// once rather than a subscription it would only ever read one value from.
  Future<List<ChannelCategoryRow>> allCategories() =>
      _ordered(db.select(db.channelCategories)).get();

  SimpleSelectStatement<$ChannelCategoriesTable, ChannelCategoryRow> _ordered(
    SimpleSelectStatement<$ChannelCategoriesTable, ChannelCategoryRow> query,
  ) =>
      query
        ..orderBy([
          (c) => OrderingTerm(expression: c.position),
          (c) => OrderingTerm(expression: c.id),
        ]);

  /// Replaces the whole known category list with exactly what the server
  /// returned. Its own replace path, never shared with [MessageStore.
  /// replaceChannels]: a category is not a channel and never appears in that
  /// list, so pruning it there would delete every category on the very
  /// first channel refresh.
  Future<void> replaceCategories(List<api.ChannelCategory> categories) async {
    await db.transaction(() async {
      await db.batch((batch) {
        for (final category in categories) {
          batch.insert(
            db.channelCategories,
            _companion(category),
            onConflict: DoUpdate(
              (_) => ChannelCategoriesCompanion.custom(
                name: Variable(category.name),
                position: Variable(category.position),
                parentId: Variable(category.parentId),
                manageable: Variable(category.manageable),
                fileable: Variable(category.fileable),
              ),
            ),
          );
        }
      });
      final keep = categories.map((c) => c.id).toSet();
      await (db.delete(db.channelCategories)..where((c) => c.id.isNotIn(keep)))
          .go();
    });
  }

  /// Inserts or updates a single category, the way the categories screen
  /// applies its own create/rename/reposition immediately rather than
  /// waiting on the `CategoryChanged` live event to round-trip back to this
  /// same client - the same instant-feedback shape
  /// `create_channel_sheet.dart` already uses for a freshly created channel.
  Future<void> upsertCategory(api.ChannelCategory category) {
    return db
        .into(db.channelCategories)
        .insertOnConflictUpdate(_companion(category));
  }

  ChannelCategoriesCompanion _companion(api.ChannelCategory category) =>
      ChannelCategoriesCompanion.insert(
        id: category.id,
        name: category.name,
        position: Value(category.position),
        parentId: Value(category.parentId),
        manageable: Value.absentIfNull(category.manageable),
        fileable: Value.absentIfNull(category.fileable),
      );

  /// Removes one category locally, the immediate-feedback counterpart to
  /// [upsertCategory], and lifts its sub-categories to the top level the way
  /// the server's delete does. Never touches [Channels]: the next refresh
  /// (triggered by the same `CategoryChanged` event) moves them.
  Future<void> removeCategory(String categoryId) => db.transaction(() async {
        await (db.update(db.channelCategories)
              ..where((c) => c.parentId.equals(categoryId)))
            .write(const ChannelCategoriesCompanion(parentId: Value(null)));
        await (db.delete(db.channelCategories)
              ..where((c) => c.id.equals(categoryId)))
            .go();
      });
}
