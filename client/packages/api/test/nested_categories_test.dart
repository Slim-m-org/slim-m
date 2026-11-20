// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Nested categories (decision 0120) on the wire: `parent_id` on a category,
/// whether the server nests at all, and the move, arrangement and sync calls.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'u1',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    );

Map<String, dynamic> _category(String id, {Object? parent = const _Absent()}) =>
    {
      'id': id,
      'name': 'name-$id',
      'position': 0,
      'created_at': 1,
      if (parent is! _Absent) 'parent_id': parent,
    };

class _Absent {
  const _Absent();
}

/// A client whose every request is recorded and answered with [reply].
(SlimmApi, List<http.Request>) _api(Object reply) {
  final sent = <http.Request>[];
  final api = SlimmApi(
    baseUrl: _base,
    session: SessionStore(tokens: _tokens()),
    httpClient: MockClient((request) async {
      sent.add(request);
      return http.Response(
        jsonEncode(reply),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  );
  return (api, sent);
}

void main() {
  group('ChannelCategory.fromJson', () {
    test('reads a sub-category parent', () {
      final category = ChannelCategory.fromJson(_category('c', parent: 'p'));
      expect(category.parentId, 'p');
      expect(category.serverNests, isTrue);
    });

    test('a null parent is a top-level category on a server that nests', () {
      final category = ChannelCategory.fromJson(_category('c', parent: null));
      expect(category.parentId, isNull);
      expect(category.serverNests, isTrue);
    });

    test('no parent_id key at all is a server that does not nest', () {
      final category = ChannelCategory.fromJson(_category('c'));
      expect(category.parentId, isNull);
      expect(category.serverNests, isFalse);
    });

    test(
        'a heading is not the caller\'s to manage; no flag is null, not allowed',
        () {
      final heading = ChannelCategory.fromJson({
        ..._category('c', parent: null),
        'manageable': false,
      });
      expect(heading.manageable, isFalse);
      expect(heading.fileable, isNull);
      final old = ChannelCategory.fromJson(_category('c'));
      expect((old.manageable, old.fileable), (null, null));
    });
  });

  test('createCategory names the parent only when given one', () async {
    final (api, sent) = _api(_category('c', parent: 'p'));
    addTearDown(api.close);
    final created = await api.createCategory('cs2', id: 'c', parentId: 'p');
    expect(created.parentId, 'p');
    expect(jsonDecode(sent.single.body), {
      'id': 'c',
      'name': 'cs2',
      'parent_id': 'p',
    });

    await api.createCategory('gamers');
    expect(jsonDecode(sent.last.body), {'name': 'gamers'});
  });

  test('moveCategory sends a null parent to move to the top level', () async {
    final (api, sent) = _api(_category('c', parent: null));
    addTearDown(api.close);
    await api.moveCategory(categoryId: 'c', parentId: null);
    expect(sent.single.method, 'PATCH');
    expect(sent.single.url.path, '/categories/c');
    final body = jsonDecode(sent.single.body) as Map<String, dynamic>;
    expect(body.containsKey('parent_id'), isTrue);
    expect(body['parent_id'], isNull);
    expect(body.containsKey('position'), isFalse);

    await api.moveCategory(categoryId: 'c', parentId: 'p', position: 2);
    expect(jsonDecode(sent.last.body), {'parent_id': 'p', 'position': 2});
  });

  test('reorderCategories PUTs every group and reads the tree back', () async {
    final (api, sent) = _api([
      _category('p', parent: null),
      _category('c', parent: 'p'),
    ]);
    addTearDown(api.close);
    final listed = await api.reorderCategories(const [
      CategoryOrderGroup(parentId: null, categoryIds: ['p']),
      CategoryOrderGroup(parentId: 'p', categoryIds: ['c']),
    ]);
    expect(sent.single.method, 'PUT');
    expect(sent.single.url.path, '/categories/order');
    expect(jsonDecode(sent.single.body), {
      'groups': [
        {
          'parent_id': null,
          'category_ids': ['p'],
        },
        {
          'parent_id': 'p',
          'category_ids': ['c'],
        },
      ],
    });
    expect(listed.map((c) => c.parentId), [null, 'p']);
  });

  group('a category overwrite set', () {
    final rows = [
      {'kind': 'role', 'id': 'r1', 'allow': 1, 'deny': 0},
    ];

    test('a top-level category carries no synced flag', () async {
      final (api, sent) = _api({'overwrites': rows});
      addTearDown(api.close);
      final set = await api.getCategoryOverwriteSet('k');
      expect(sent.single.url.path, '/categories/k/overwrites');
      expect(set.synced, isNull);
      expect(set.overwrites.single.id, 'r1');
    });

    test('a sub-category says whether it follows its parent', () async {
      final (api, _) = _api({'overwrites': rows, 'synced': false});
      addTearDown(api.close);
      expect((await api.getCategoryOverwriteSet('k')).synced, isFalse);
    });

    test('syncCategoryOverwrites POSTs the sync route', () async {
      final (api, sent) = _api({'overwrites': rows, 'synced': true});
      addTearDown(api.close);
      final set = await api.syncCategoryOverwrites('k');
      expect(sent.single.method, 'POST');
      expect(sent.single.url.path, '/categories/k/overwrites/sync');
      expect(set.synced, isTrue);
    });
  });
}
