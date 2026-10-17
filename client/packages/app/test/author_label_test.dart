// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Coverage for `authorLabel`, the one place a message author's name is
/// resolved: the fix for the recorded debt that a renamed author's
/// already-cached messages never reconciled on any other client.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/widgets/author_label.dart';

api.UserProfile _profile(String id, String name) =>
    api.UserProfile(id: id, username: id, displayName: name, createdAt: 0);

void main() {
  test('an author never resolved falls back to the cached name', () {
    expect(
      authorLabel(
        authorId: 'u1',
        cachedDisplayName: 'Old Name',
        profiles: const {},
      ),
      'Old Name',
    );
  });

  test('an author never resolved and never cached reads as Unknown', () {
    expect(
      authorLabel(authorId: 'u1', cachedDisplayName: null, profiles: const {}),
      'Unknown',
    );
  });

  test('a resolved profile wins over a stale cached name', () {
    expect(
      authorLabel(
        authorId: 'u1',
        cachedDisplayName: 'Old Name',
        profiles: {'u1': _profile('u1', 'New Name')},
      ),
      'New Name',
    );
  });

  test('a confirmed-gone id reads as deleted, never the stale cached name', () {
    expect(
      authorLabel(
        authorId: 'u1',
        cachedDisplayName: 'Old Name',
        profiles: const {'u1': null},
      ),
      'Deleted user',
    );
  });

  test('a null author id is always Deleted user, resolved or not', () {
    expect(
      authorLabel(
        authorId: null,
        cachedDisplayName: 'Whoever cached this',
        profiles: const {},
      ),
      'Deleted user',
    );
  });
}
