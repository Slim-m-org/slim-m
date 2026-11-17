// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who can see a channel or a category, read from and written to its
/// permission overwrites: `@everyone` denied View makes it private, and an
/// Allow View row on a role or member lets them in (decision 0125).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/providers.dart' show apiProvider;

/// The overwrites one channel or one category holds, and how to write them.
sealed class ViewTarget {
  const ViewTarget();

  AutoDisposeFutureProvider<List<api.ChannelOverwrite>> get overwrites;

  /// Applies [edits]; an all-zero pair removes that row.
  Future<void> write(api.SlimmApi client, List<api.ChannelOverwriteEdit> edits);

  /// What a write here leaves stale.
  List<ProviderOrFamily> get affected;
}

final class ChannelViewTarget extends ViewTarget {
  const ChannelViewTarget(this.channelId);

  final String channelId;

  @override
  AutoDisposeFutureProvider<List<api.ChannelOverwrite>> get overwrites =>
      channelOverwritesProvider(channelId);

  @override
  Future<void> write(
    api.SlimmApi client,
    List<api.ChannelOverwriteEdit> edits,
  ) async {
    final kept = [
      for (final edit in edits)
        if (edit.allow != 0 || edit.deny != 0) edit,
    ];
    for (final edit in edits.where((e) => !kept.contains(e))) {
      await client.deleteChannelOverwrite(
        channelId: channelId,
        kind: edit.kind,
        id: edit.id,
      );
    }
    if (kept.isEmpty) return;
    await client.batchSetChannelOverwrites(
      channelId: channelId,
      overwrites: kept,
    );
  }

  @override
  List<ProviderOrFamily> get affected => [
    overwrites,
    channelOverwritesSyncedProvider(channelId),
  ];

  @override
  bool operator ==(Object other) =>
      other is ChannelViewTarget && other.channelId == channelId;

  @override
  int get hashCode => Object.hash(ChannelViewTarget, channelId);
}

final class CategoryViewTarget extends ViewTarget {
  const CategoryViewTarget(this.categoryId);

  final String categoryId;

  @override
  AutoDisposeFutureProvider<List<api.ChannelOverwrite>> get overwrites =>
      categoryOverwritesProvider(categoryId);

  @override
  Future<void> write(
    api.SlimmApi client,
    List<api.ChannelOverwriteEdit> edits,
  ) => client.batchSetCategoryOverwrites(
    categoryId: categoryId,
    overwrites: edits,
  );

  // A sub-category's own save stops it following its parent.
  @override
  List<ProviderOrFamily> get affected => [
    overwrites,
    categoryOverwritesSyncedProvider(categoryId),
  ];

  @override
  bool operator ==(Object other) =>
      other is CategoryViewTarget && other.categoryId == categoryId;

  @override
  int get hashCode => Object.hash(CategoryViewTarget, categoryId);
}

/// What a set of overwrites says about who can see the thing they sit on.
class ViewAccess {
  const ViewAccess({required this.private, required this.viewers});

  factory ViewAccess.of(
    List<api.ChannelOverwrite> overwrites, {
    required String everyoneRoleId,
  }) {
    bool isEveryone(api.ChannelOverwrite o) =>
        o.kind == api.OverwriteTarget.role && o.id == everyoneRoleId;
    final everyone = overwrites.where(isEveryone).firstOrNull;
    return ViewAccess(
      private: (everyone?.deny ?? 0) & Perm.viewChannel != 0,
      viewers: [
        for (final o in overwrites)
          if (!isEveryone(o) && o.allow & Perm.viewChannel != 0) o,
      ],
    );
  }

  /// `@everyone` is denied View.
  final bool private;

  /// The roles and members an Allow View row lets in.
  final List<api.ChannelOverwrite> viewers;
}

api.ChannelOverwrite? _find(
  List<api.ChannelOverwrite> existing,
  api.OverwriteTarget kind,
  String id,
) => existing.where((o) => o.kind == kind && o.id == id).firstOrNull;

/// The edit that sets or clears [kind]:[id]'s View allow, keeping its other bits.
api.ChannelOverwriteEdit viewGrantEdit(
  List<api.ChannelOverwrite> existing, {
  required api.OverwriteTarget kind,
  required String id,
  required bool allowed,
}) {
  final row = _find(existing, kind, id);
  final allow = row?.allow ?? 0;
  return api.ChannelOverwriteEdit(
    kind: kind,
    id: id,
    allow: allowed ? allow | Perm.viewChannel : allow & ~Perm.viewChannel,
    deny: allowed ? (row?.deny ?? 0) & ~Perm.viewChannel : (row?.deny ?? 0),
  );
}

/// The edits that deny `@everyone` View and, given [selfId], keep it for them.
List<api.ChannelOverwriteEdit> privateEdits(
  List<api.ChannelOverwrite> existing, {
  required String everyoneRoleId,
  String? selfId,
}) {
  final everyone = _find(existing, api.OverwriteTarget.role, everyoneRoleId);
  return [
    if (selfId != null)
      viewGrantEdit(
        existing,
        kind: api.OverwriteTarget.member,
        id: selfId,
        allowed: true,
      ),
    api.ChannelOverwriteEdit(
      kind: api.OverwriteTarget.role,
      id: everyoneRoleId,
      allow: (everyone?.allow ?? 0) & ~Perm.viewChannel,
      deny: (everyone?.deny ?? 0) | Perm.viewChannel,
    ),
  ];
}

/// The edit that lifts only `@everyone`'s View deny, or none when there is no row.
List<api.ChannelOverwriteEdit> publicEdits(
  List<api.ChannelOverwrite> existing, {
  required String everyoneRoleId,
}) {
  final everyone = _find(existing, api.OverwriteTarget.role, everyoneRoleId);
  if (everyone == null) return const [];
  return [
    api.ChannelOverwriteEdit(
      kind: api.OverwriteTarget.role,
      id: everyoneRoleId,
      allow: everyone.allow,
      deny: everyone.deny & ~Perm.viewChannel,
    ),
  ];
}

/// Writes a [ViewTarget]'s rows for a widget, which never reads the api itself.
class ViewAccessWriter {
  const ViewAccessWriter(this._client);

  final api.SlimmApi _client;

  Future<void> write(ViewTarget target, List<api.ChannelOverwriteEdit> edits) =>
      target.write(_client, edits);
}

final viewAccessWriterProvider = Provider<ViewAccessWriter>(
  (ref) => ViewAccessWriter(ref.watch(apiProvider)),
);
