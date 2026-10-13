// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// A channel's overwrites with whether they follow its category.
class ChannelOverwriteSet {
  const ChannelOverwriteSet({required this.overwrites, required this.synced});

  final List<ChannelOverwrite> overwrites;

  /// True while the channel carries a copy of its category's overwrites.
  final bool synced;
}

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
        await _send('GET', '/categories/$categoryId/overwrites'),
      );

  /// Applies the edits to the category (an all-zero pair removes that target)
  /// and copies the result into every channel synced to it.
  Future<List<ChannelOverwrite>> batchSetCategoryOverwrites({
    required String categoryId,
    required List<ChannelOverwriteEdit> overwrites,
  }) async =>
      _overwritesOf(
        await _send(
          'PUT',
          '/categories/$categoryId/overwrites',
          body: _editsBody(overwrites),
        ),
      );

  /// A channel's overwrites and whether they follow its category.
  Future<ChannelOverwriteSet> getChannelOverwriteSet(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/overwrites');
    return ChannelOverwriteSet(
      overwrites: _overwritesOf(json),
      synced: (json as Map<String, dynamic>)['synced'] as bool? ?? false,
    );
  }

  /// Makes the channel follow its category again, adopting its overwrites.
  Future<List<ChannelOverwrite>> syncChannelOverwrites(
          String channelId) async =>
      _overwritesOf(
        await _send('POST', '/channels/$channelId/overwrites/sync'),
      );
}
