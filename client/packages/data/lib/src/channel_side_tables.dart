// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:drift/drift.dart';

/// Locally cached channel categories: a rail section a channel of any kind
/// may be filed under. Replaced wholesale on its own path
/// ([MessageStore.replaceCategories]), never pruned by [Channels]'s own
/// replace - a category is not a channel and never appears in that list, the
/// same shape a thread needed exempting from `replaceChannels`'s pruning.
///
/// `@DataClassName('ChannelCategoryRow')`: drift's default singular name for
/// this table would be `ChannelCategory`, which collides with `slimm_api`'s
/// own wire model of that exact name - the two would be indistinguishable by
/// name in any file that imports both.
@DataClassName('ChannelCategoryRow')
class ChannelCategories extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();

  /// Sort key among its siblings, lower first: the top-level categories, or
  /// one parent's sub-categories (decision 0120).
  IntColumn get position => integer().withDefault(const Constant(0))();

  /// The top-level category this one sits in, or null for a top-level one.
  TextColumn get parentId => text().nullable()();

  /// Whether this account may rename, move or delete it; false for a heading
  /// only, null before a listing said, read through `CategoryReach`.
  BoolColumn get manageable => boolean().nullable()();

  /// Whether this account may file a channel or sub-category under it; null as above.
  BoolColumn get fileable => boolean().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Unsent composer text, one row per channel.
///
/// The one table here that is not a cache of server state: nobody else has
/// these words, so unlike [Messages] a wipe loses something real rather than
/// something refetchable. That is why it is written at all - on a phone, the OS
/// killing a backgrounded app is indistinguishable from a restart to the person
/// who just lost what they typed, and it happens without anyone choosing it.
///
/// Still wiped on sign-out, along with everything else: the next account on this
/// device must never read the last one's unfinished words.
@DataClassName('ChannelDraftRow')
class ChannelDrafts extends Table {
  TextColumn get channelId => text()();

  /// Never empty. An empty draft and no draft have to read the same way, so the
  /// controller deletes the row rather than storing a blank one.
  ///
  /// Named `body` rather than `text`: a column called `text` shadows drift's own
  /// `text()` builder, so the getter recursively returns itself and the analyzer
  /// is the only thing that catches it.
  TextColumn get body => text()();

  /// When it was last typed, so a future "you have unsent drafts" surface can
  /// order them without another migration. Nothing reads it yet.
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {channelId};
}

/// One viewer's own layout of one channel's canvas, camera and tile places; never sent anywhere (decision 0082).
/// The database is one per account (decision 0068), so the channel id alone keys it.
@DataClassName('CanvasPersonalLayoutRow')
class CanvasPersonalLayouts extends Table {
  TextColumn get channelId => text()();

  /// The layout as the voice canvas encodes it; this package never reads it.
  TextColumn get layout => text()();

  /// Orders rows so the oldest go first when the table is capped.
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {channelId};
}
