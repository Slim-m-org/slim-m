// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a carried category may land in the two-level tree (decision 0120),
/// and what a drop there sends: never a third level.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show CategoryOrderGroup;
import 'package:slimm_app/src/features/channels/widgets/category_tree.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_reorder.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_category_slots.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_drop_slots.dart';
import 'package:slimm_data/data.dart';

Channel _channel(String id, String categoryId) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
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

final _tree = CategoryTree([
  _cat('gamers'),
  _cat('minecraft', parentId: 'gamers'),
  _cat('cs2', position: 1, parentId: 'gamers'),
  _cat('music', position: 1),
]);

List<ChannelSection> _sections() => [
  (null, const []),
  (_tree.byId['gamers'], [_channel('gg', 'gamers')]),
  (_tree.byId['minecraft'], [_channel('mc', 'minecraft')]),
  (_tree.byId['cs2'], [_channel('csa', 'cs2'), _channel('csb', 'cs2')]),
  (_tree.byId['music'], [_channel('jazz', 'music')]),
];

const _header = 28.0;
const _row = 40.0;

/// Every item stacked top to bottom; [folded] sections take no height.
List<RailBox> _boxes({Set<int> folded = const {}, int? placeholder}) {
  final boxes = <RailBox>[];
  var y = 0.0;
  void add(RailBoxKind kind, int section, double height) {
    boxes.add(
      RailBox(kind: kind, section: section, top: y, bottom: y + height),
    );
    y += height;
  }

  final sections = _sections();
  for (var s = 0; s < sections.length; s++) {
    final gone = folded.contains(s);
    add(
      RailBoxKind.header,
      s,
      s == 0 || (gone && s != placeholder) ? 0 : _header,
    );
    for (final _ in sections[s].$2) {
      add(RailBoxKind.channel, s, gone ? 0 : _row);
    }
  }
  return boxes;
}

DropSlot? _at(
  String carried,
  double y, {
  List<RailBox>? boxes,
  bool nests = true,
}) => categorySlotAt(
  boxes ?? _boxes(),
  CategoryCarry(
    sections: _sections(),
    tree: _tree,
    carriedId: carried,
    closed: const {},
    inset: 16,
    nests: nests,
  ),
  y,
);

List<String>? _shape(List<CategoryOrderGroup>? groups) => groups == null
    ? null
    : [for (final g in groups) '${g.parentId}:${g.categoryIds.join(',')}'];

void main() {
  // Header and row edges: gamers 0-68, minecraft 68-136, cs2 136-244, music 244-312.
  test('above the end of a block files the category inside it', () {
    final slot = _at('music', 240)!;

    expect(slot.parentId, 'gamers');
    expect(slot.inset, 16);
    expect(slot.refused, isFalse);
    expect(_shape(categoryGroupsAfterDrop(_tree, 'music', slot)), [
      'null:gamers',
      'gamers:minecraft,cs2,music',
    ]);
  });

  test('below the same edge starts the next top-level block', () {
    final slot = _at('music', 248)!;

    expect(slot.parentId, isNull);
    expect(slot.inset, 0);
    expect(categoryGroupsAfterDrop(_tree, 'music', slot), isNull);
  });

  test('a gap between a sub-category\'s rows is refused', () {
    final slot = _at('music', 200)!;

    expect(slot.refused, isTrue);
    expect(slot.inset, 32, reason: 'the line sits where a third level would');
    expect(categoryGroupsAfterDrop(_tree, 'music', slot), isNull);
  });

  test('a category with sub-categories may not be filed under another', () {
    final lifted = _boxes(folded: {1, 2, 3}, placeholder: 1);
    final musicBottom = lifted.last.bottom;

    final inside = _at('gamers', musicBottom - 4, boxes: lifted)!;
    expect(inside.refused, isTrue);
    expect(inside.parentId, 'music');
    expect(categoryGroupsAfterDrop(_tree, 'gamers', inside), isNull);

    final after = _at('gamers', musicBottom + 4, boxes: lifted)!;
    expect(after.refused, isFalse);
    expect(_shape(categoryGroupsAfterDrop(_tree, 'gamers', after)), [
      'null:music,gamers',
      'gamers:minecraft,cs2',
    ]);
  });

  test('a sub-category dropped between top-level blocks is promoted', () {
    final slot = _at('cs2', 248)!;

    expect(_shape(categoryGroupsAfterDrop(_tree, 'cs2', slot)), [
      'null:gamers,cs2,music',
      'gamers:minecraft',
    ]);
  });

  test('a server that does not nest is offered top-level gaps only', () {
    for (final y in [96.0, 200.0, 240.0]) {
      final slot = _at('music', y, nests: false)!;
      expect(slot.parentId, isNull, reason: 'at $y');
      expect(slot.refused, isFalse, reason: 'at $y');
    }
  });

  test('no gap inside its own block is offered to a lifted parent', () {
    final lifted = _boxes(folded: {1, 2, 3}, placeholder: 1);
    final slot = _at('gamers', 10, boxes: lifted)!;

    expect(slot.parentId, isNull);
  });

  group('groupsAfterSiblingStep', () {
    test('moves a sub-category among its own siblings only', () {
      expect(_shape(groupsAfterSiblingStep(_tree, 'cs2', -1)), [
        'null:gamers,music',
        'gamers:cs2,minecraft',
      ]);
      expect(groupsAfterSiblingStep(_tree, 'minecraft', -1), isNull);
      expect(groupsAfterSiblingStep(_tree, 'cs2', 1), isNull);
    });

    test('moves a top-level category with its sub-categories', () {
      expect(_shape(groupsAfterSiblingStep(_tree, 'gamers', 1)), [
        'null:music,gamers',
        'gamers:minecraft,cs2',
      ]);
    });
  });
}
