// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two-level category tree the rail draws (decision 0120): its order,
/// which sections a member is shown, and what a fold closes.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/category_tree.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_grouping.dart';
import 'package:slimm_data/data.dart';

Channel _channel(String id, String? categoryId, {int position = 0}) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: position,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: categoryId,
);

ChannelCategoryRow _cat(String id, {int position = 0, String? parentId}) =>
    ChannelCategoryRow(
      id: id,
      name: id,
      position: position,
      parentId: parentId,
    );

final _gamers = _cat('gamers');
final _music = _cat('music', position: 1);
final _minecraft = _cat('minecraft', parentId: 'gamers');
final _cs2 = _cat('cs2', position: 1, parentId: 'gamers');

/// The store hands rows back by position alone, so siblings of different parents interleave.
final _asStored = [_gamers, _minecraft, _cs2, _music];

List<String?> _ids(Iterable<(ChannelCategoryRow?, List<Channel>)> sections) => [
  for (final (category, _) in sections) category?.id,
];

void main() {
  test('each top-level category is followed by its own sub-categories', () {
    final tree = CategoryTree(_asStored);

    expect(tree.ordered.map((c) => c.id), [
      'gamers',
      'minecraft',
      'cs2',
      'music',
    ]);
    expect(tree.topLevel.map((c) => c.id), ['gamers', 'music']);
    expect(tree.depthOf(_cs2), 1);
    expect(tree.depthOf(_gamers), 0);
    expect(tree.pathOf(_cs2), 'gamers / cs2');
    expect(tree.pathOf(_music), 'music');
  });

  test('a sub-category whose parent is not held draws at the top level, '
      'after every block', () {
    final orphan = _cat('cs2', parentId: 'gone');
    final tree = CategoryTree([orphan, _gamers]);

    expect(tree.ordered.map((c) => c.id), ['gamers', 'cs2']);
    expect(tree.depthOf(orphan), 0);
    expect(tree.parentOf(orphan), isNull);
  });

  test(
    'a row naming a sub-category as its parent never draws a third level',
    () {
      final deep = _cat('dust2', parentId: 'cs2');
      final tree = CategoryTree([..._asStored, deep]);

      expect(tree.depthOf(deep), 0);
      expect(tree.childrenOf('cs2'), isEmpty);
    },
  );

  test('orderedChannels walks a parent\'s own channels before its '
      'sub-categories\'', () {
    final ordered = orderedChannels([
      _channel('cs-general', 'cs2'),
      _channel('gamers-general', 'gamers'),
      _channel('mc-general', 'minecraft'),
      _channel('loose', null),
    ], _asStored);

    expect(ordered.map((c) => c.id), [
      'loose',
      'gamers-general',
      'mc-general',
      'cs-general',
    ]);
  });

  group('railSections', () {
    test('a cs-only member sees gamers as a container over cs2 alone', () {
      final sections = railSections(
        [_channel('cs-general', 'cs2')],
        CategoryTree([_gamers, _cs2]),
        canManage: false,
      );

      expect(_ids(sections), ['gamers', 'cs2']);
      expect(sections.first.$2, isEmpty, reason: 'none of gamers\' own');
    });

    test('a parent with nothing visible beneath it is not shown', () {
      final sections = railSections(
        [_channel('jazz', 'music')],
        CategoryTree(_asStored),
        canManage: false,
      );

      expect(_ids(sections), ['music']);
    });

    test('a manager sees every category at both levels, empty ones too', () {
      final sections = railSections(
        const [],
        CategoryTree(_asStored),
        canManage: true,
      );

      expect(_ids(sections), [null, 'gamers', 'minecraft', 'cs2', 'music']);
    });
  });

  test('folding a parent closes its sub-categories too', () {
    final tree = CategoryTree(_asStored);
    final sections = railSections(const [], tree, canManage: true);

    expect(closedSections(sections, tree, {'gamers'}), {1, 2, 3});
    expect(closedSections(sections, tree, {'cs2'}), {3});
  });

  test('the arrangement names every category once, a group per parent', () {
    final groups = CategoryTree(_asStored).groups;

    expect(
      [for (final g in groups) '${g.parentId}:${g.categoryIds.join(',')}'],
      ['null:gamers,music', 'gamers:minecraft,cs2'],
    );
  });
}
