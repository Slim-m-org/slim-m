// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// A channel's overwrites with whether they follow its category.
class ChannelOverwriteSet {
  const ChannelOverwriteSet({required this.overwrites, required this.synced});

  final List<ChannelOverwrite> overwrites;

  /// True while the channel carries a copy of its category's overwrites.
  final bool synced;
}

/// A category's overwrites with, for a sub-category, whether they follow its
/// parent (decision 0120).
class CategoryOverwriteSet {
  const CategoryOverwriteSet({required this.overwrites, this.synced});

  final List<ChannelOverwrite> overwrites;

  /// Null for a top-level category, which never follows anything.
  final bool? synced;
}

CategoryOverwriteSet _categorySetOf(Object? json) => CategoryOverwriteSet(
      overwrites: _overwritesOf(json),
      synced: (json as Map<String, dynamic>)['synced'] as bool?,
    );

List<ChannelOverwrite> _overwritesOf(Object? json) =>
    ((json as Map<String, dynamic>)['overwrites'] as List<dynamic>)
        .map((o) => ChannelOverwrite.fromJson(o as Map<String, dynamic>))
        .toList(growable: false);

Map<String, dynamic> _editsBody(List<ChannelOverwriteEdit> edits) => {
      'overwrites': [
        for (final edit in edits)
          {
            'kind': edit.kind.wire,
            'id': edit.id,
            'allow': edit.allow,
            'deny': edit.deny,
          },
      ],
    };

/// Category permissions (decision 0064). The writes require MANAGE_ROLES.
extension SlimmApiCategoryPermissions on SlimmApi {
  Future<List<ChannelOverwrite>> getCategoryOverwrites(
    String categoryId,
  ) async =>
      _overwritesOf(
        await send('GET', '/categories/$categoryId/overwrites'),
      );

  /// A category's overwrites and, for a sub-category, whether they follow its parent.
  Future<CategoryOverwriteSet> getCategoryOverwriteSet(
    String categoryId,
  ) async =>
      _categorySetOf(await send('GET', '/categories/$categoryId/overwrites'));

  /// Makes a sub-category follow its parent again, copying on into its synced
  /// channels. A 409 on a top-level category.
  Future<CategoryOverwriteSet> syncCategoryOverwrites(
    String categoryId,
  ) async =>
      _categorySetOf(
        await send('POST', '/categories/$categoryId/overwrites/sync'),
      );

  /// Applies the edits (an all-zero pair removes that target) and copies the result
  /// into everything synced beneath; a sub-category's own save stops it following.
  Future<List<ChannelOverwrite>> batchSetCategoryOverwrites({
    required String categoryId,
    required List<ChannelOverwriteEdit> overwrites,
  }) async =>
      _overwritesOf(
        await send(
          'PUT',
          '/categories/$categoryId/overwrites',
          body: _editsBody(overwrites),
        ),
      );

  /// A channel's overwrites and whether they follow its category.
  Future<ChannelOverwriteSet> getChannelOverwriteSet(String channelId) async {
    final json = await send('GET', '/channels/$channelId/overwrites');
    return ChannelOverwriteSet(
      overwrites: _overwritesOf(json),
      synced: (json as Map<String, dynamic>)['synced'] as bool? ?? false,
    );
  }

  /// Makes the channel follow its category again, adopting its overwrites.
  Future<List<ChannelOverwrite>> syncChannelOverwrites(
          String channelId) async =>
      _overwritesOf(
        await send('POST', '/channels/$channelId/overwrites/sync'),
      );
}
