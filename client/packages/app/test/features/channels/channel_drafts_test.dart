// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ChannelDraftsController`: the plain get/save/clear contract, the sign-out
/// and account-switch wipes that close the same leak `BlocksController` already
/// closed (a draft is the same shape as a blocked-user list - session state a
/// device must not hand to whoever signs in next), and the restore that makes a
/// draft survive the process.
///
/// The persistence cases run against a real in-memory database rather than a
/// fake store, because what is being tested is that the words come back - and a
/// fake that returns whatever it was handed would prove that whatever happens.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_drafts.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';

const _alice = api.TokenPair(
  userId: 'alice',
  accessToken: 'a-access',
  refreshToken: 'a-refresh',
  accessExpiresAt: 0,
);

const _bob = api.TokenPair(
  userId: 'bob',
  accessToken: 'b-access',
  refreshToken: 'b-refresh',
  accessExpiresAt: 0,
);

void main() {
  late api.SessionStore session;
  late ProviderContainer container;

  setUp(() {
    session = api.SessionStore(tokens: _alice);
    container = ProviderContainer(
      overrides: [sessionProvider.overrideWithValue(session)],
    );
    addTearDown(container.dispose);
  });

  test('a channel with nothing saved has an empty draft', () {
    final drafts = container.read(channelDraftsProvider);
    expect(drafts.draftFor('c1'), isEmpty);
  });

  test('saving and reading back a draft round-trips per channel', () {
    final drafts = container.read(channelDraftsProvider);
    drafts.save('c1', 'hello there');
    drafts.save('c2', 'a different message');

    expect(drafts.draftFor('c1'), 'hello there');
    expect(drafts.draftFor('c2'), 'a different message');
  });

  test('saving an empty string forgets the draft rather than keeping one', () {
    final drafts = container.read(channelDraftsProvider);
    drafts.save('c1', 'hello there');
    drafts.save('c1', '');

    expect(
      drafts.draftFor('c1'),
      isEmpty,
      reason:
          'an empty draft and no draft must read the same way, or a '
          'channel visited and left empty grows the map forever',
    );
  });

  test('clear forgets a channel outright, called once its text is sent', () {
    final drafts = container.read(channelDraftsProvider);
    drafts.save('c1', 'hello there');
    drafts.clear('c1');

    expect(drafts.draftFor('c1'), isEmpty);
  });

  test('signing out empties every draft', () async {
    final drafts = container.read(channelDraftsProvider);
    drafts.save('c1', 'hello there');

    session.set(null);
    // The session's changes are a broadcast stream, delivered on a microtask.
    await Future<void>.value();

    expect(
      drafts.draftFor('c1'),
      isEmpty,
      reason:
          'the local database is one file for the whole app; a draft '
          'outliving sign-out would hand it to whoever signs in next',
    );
  });

  test(
    'a different account signing in on this process empties every draft',
    () async {
      final drafts = container.read(channelDraftsProvider);
      drafts.save('c1', 'hello there');

      session.set(_bob);
      await Future<void>.value();

      expect(drafts.draftFor('c1'), isEmpty);
    },
  );

  test('a token rotation for the same account keeps its drafts', () async {
    final drafts = container.read(channelDraftsProvider);
    drafts.save('c1', 'hello there');

    session.set(
      const api.TokenPair(
        userId: 'alice',
        accessToken: 'rotated-access',
        refreshToken: 'rotated-refresh',
        accessExpiresAt: 1000,
      ),
    );
    await Future<void>.value();

    expect(
      drafts.draftFor('c1'),
      'hello there',
      reason:
          'the session stream also fires on routine access-token rotation, '
          'not just a real account change',
    );
  });

  group('surviving the process', () {
    /// A container wired to [db], so two of them in a row are what a restart
    /// looks like from the controller's side.
    ProviderContainer containerOn(SlimmDatabase db, api.SessionStore session) {
      final made = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(session),
          storeProvider.overrideWith((ref) async => MessageStore(db)),
        ],
      );
      addTearDown(made.dispose);
      return made;
    }

    test('a draft typed before a restart is there after one', () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final first = containerOn(db, api.SessionStore(tokens: _alice));
      final before = first.read(channelDraftsProvider);
      await before.restored;
      before.save('c1', 'half a thought');
      // The write is fire-and-forget by design, so let it land.
      await Future<void>.delayed(Duration.zero);
      await pumpEventQueue();

      final second = containerOn(db, api.SessionStore(tokens: _alice));
      final after = second.read(channelDraftsProvider);
      await after.restored;

      expect(after.draftFor('c1'), 'half a thought');
    });

    test('a draft restored before the session loads survives the sign-in '
        'that loading reports', () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await MessageStore(db).saveDraft('c1', 'half a thought', now: 1);

      final coldSession = api.SessionStore();
      final drafts = containerOn(db, coldSession).read(channelDraftsProvider);
      await drafts.restored;
      coldSession.set(_alice);
      await pumpEventQueue();

      expect(
        drafts.draftFor('c1'),
        'half a thought',
        reason:
            'a cold start reads the key store after the controller is '
            'built; no account to this account is not an account change',
      );
    });

    test('a draft sent before the restart does not come back', () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);

      final first = containerOn(db, api.SessionStore(tokens: _alice));
      final before = first.read(channelDraftsProvider);
      await before.restored;
      before.save('c1', 'about to send this');
      await pumpEventQueue();
      before.clear('c1');
      await pumpEventQueue();

      final second = containerOn(db, api.SessionStore(tokens: _alice));
      final after = second.read(channelDraftsProvider);
      await after.restored;

      expect(after.draftFor('c1'), isEmpty);
    });

    test('typing during the restore wins over what was on disk', () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      await MessageStore(db).saveDraft('c1', 'the old words', now: 1);

      final container = containerOn(db, api.SessionStore(tokens: _alice));
      final drafts = container.read(channelDraftsProvider);
      // Before the restore has had a chance to land.
      drafts.save('c1', 'the new words');
      await drafts.restored;

      expect(
        drafts.draftFor('c1'),
        'the new words',
        reason: 'somebody typing states a newer intent than a row being read',
      );
    });

    test('a restore that fails leaves the controller usable', () async {
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _alice)),
          storeProvider.overrideWith(
            (ref) async => throw StateError('no database here'),
          ),
        ],
      );
      addTearDown(container.dispose);

      final drafts = container.read(channelDraftsProvider);
      await drafts.restored;
      drafts.save('c1', 'still works');

      expect(
        drafts.draftFor('c1'),
        'still works',
        reason:
            'a draft that cannot be read back is the loss a crash already '
            'was; it must not also break the composer',
      );
    });
  });
}
