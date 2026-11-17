// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `CategoryStore`, the client half of channel categories -
/// see docs/decisions/0006-channel-categories.md.
///
/// [CategoryStore.replaceCategories] is the one path with a real invariant
/// to protect: it has to prune whatever the server no longer lists, or a
/// category removed server-side lingers in this cache forever, since
/// nothing else in the client ever deletes a `channel_categories` row on
/// its own initiative.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

api.ChannelCategory _category({
  required String id,
  String name = 'Category',
  int position = 0,
  String? parentId,
}) =>
    api.ChannelCategory(
      id: id,
      name: name,
      position: position,
      createdAt: 1,
      parentId: parentId,
      serverNests: true,
    );

void main() {
  late SlimmDatabase db;
  late MessageStore store;

  setUp(() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
  });

  tearDown(() => db.close());

  test('replaceCategories inserts every category the server listed', () async {
    await store.replaceCategories([
      _category(id: 'cat-a', name: 'Alpha', position: 0),
      _category(id: 'cat-b', name: 'Beta', position: 1),
    ]);

    final rows = await store.allCategories();

    expect(rows.map((r) => r.id), ['cat-a', 'cat-b']);
    expect(rows.map((r) => r.name), ['Alpha', 'Beta']);
  });

  test(
    'replaceCategories prunes a category the server no longer lists',
    () async {
      await store.replaceCategories([
        _category(id: 'cat-a', name: 'Alpha', position: 0),
        _category(id: 'cat-b', name: 'Beta', position: 1),
      ]);

      // The next server answer no longer carries cat-b - it was deleted.
      await store.replaceCategories([
        _category(id: 'cat-a', name: 'Alpha', position: 0),
      ]);

      final rows = await store.allCategories();

      expect(
        rows.map((r) => r.id),
        ['cat-a'],
        reason: 'a category removed server-side must not linger locally '
            'forever - nothing else in this client prunes it',
      );
    },
  );

  test('replaceCategories updates a renamed or repositioned category in place',
      () async {
    await store.replaceCategories(
        [_category(id: 'cat-a', name: 'Alpha', position: 0)]);

    await store.replaceCategories(
        [_category(id: 'cat-a', name: 'Renamed', position: 3)]);

    final row = await store.allCategories();
    expect(row.single.name, 'Renamed');
    expect(row.single.position, 3);
  });

  test('allCategories and watchCategories both order by position', () async {
    await store.replaceCategories([
      _category(id: 'cat-b', name: 'Beta', position: 5),
      _category(id: 'cat-a', name: 'Alpha', position: 1),
    ]);

    final rows = await store.allCategories();
    expect(rows.map((r) => r.id), ['cat-a', 'cat-b']);

    final watched = await store.watchCategories().first;
    expect(watched.map((r) => r.id), ['cat-a', 'cat-b']);
  });

  test(
      'upsertCategory applies an immediate local create ahead of any live event',
      () async {
    await store
        .upsertCategory(_category(id: 'cat-a', name: 'Alpha', position: 0));

    final rows = await store.allCategories();
    expect(rows.single.id, 'cat-a');
  });

  test('upsertCategory updates an existing row rather than duplicating it',
      () async {
    await store
        .upsertCategory(_category(id: 'cat-a', name: 'Alpha', position: 0));
    await store
        .upsertCategory(_category(id: 'cat-a', name: 'Alpha 2', position: 0));

    final rows = await store.allCategories();
    expect(rows, hasLength(1));
    expect(rows.single.name, 'Alpha 2');
  });

  test('removeCategory deletes exactly the named category', () async {
    await store.replaceCategories([
      _category(id: 'cat-a', name: 'Alpha', position: 0),
      _category(id: 'cat-b', name: 'Beta', position: 1),
    ]);

    await store.removeCategory('cat-a');

    final rows = await store.allCategories();
    expect(rows.map((r) => r.id), ['cat-b']);
  });

  test('replaceCategories moves an existing row to its new parent and back',
      () async {
    await store.replaceCategories([
      _category(id: 'gamers'),
      _category(id: 'cs2'),
    ]);

    await store.replaceCategories([
      _category(id: 'gamers'),
      _category(id: 'cs2', parentId: 'gamers'),
    ]);
    var rows = {for (final r in await store.allCategories()) r.id: r};
    expect(rows['cs2']!.parentId, 'gamers');

    await store.replaceCategories([
      _category(id: 'gamers'),
      _category(id: 'cs2'),
    ]);
    rows = {for (final r in await store.allCategories()) r.id: r};
    expect(rows['cs2']!.parentId, isNull);
  });

  test('upsertCategory writes the parent of a moved category', () async {
    await store.upsertCategory(_category(id: 'gamers'));
    await store.upsertCategory(_category(id: 'cs2'));

    await store.upsertCategory(_category(id: 'cs2', parentId: 'gamers'));

    final rows = {for (final r in await store.allCategories()) r.id: r};
    expect(rows['cs2']!.parentId, 'gamers');
  });

  test('removeCategory lifts its sub-categories to the top level', () async {
    await store.replaceCategories([
      _category(id: 'gamers'),
      _category(id: 'cs2', parentId: 'gamers'),
      _category(id: 'minecraft', parentId: 'gamers', position: 1),
    ]);

    await store.removeCategory('gamers');

    final rows = await store.allCategories();
    expect(rows.map((r) => r.id), ['cs2', 'minecraft']);
    expect(rows.map((r) => r.parentId), [null, null]);
  });
}
