// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster a call reports: emitted only on a real change, with your own level fed apart.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/voice_models.dart';
import 'package:slimm_rtc/src/voice_roster.dart';

import 'support/reconnect_fakes.dart';
import 'support/session_fakes.dart';

void main() {
  late int refreshes;
  late bool reconnecting;
  late VoiceRoster roster;
  late List<List<String>> emitted;
  late List<double> levels;

  setUp(() {
    refreshes = 0;
    reconnecting = false;
    emitted = [];
    levels = [];
    roster = VoiceRoster(
      VoiceRosterHost(
        refresh: () => refreshes++,
        reconnecting: () => reconnecting,
        localVoice: () => null,
        deafened: () => false,
      ),
    );
    roster.changes.listen((people) => emitted.add([
          for (final p in people) p.identity,
        ]));
    roster.localLevels.listen(levels.add);
  });

  tearDown(() => roster.dispose());

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('an unchanged roster is not emitted again', () async {
    final room = InstantRoom(me: 'me');

    roster.update(room);
    roster.update(room);
    await settle();

    expect(emitted, [
      ['me']
    ]);
    expect(roster.participants.map((p) => p.identity), ['me']);
  });

  test('your level is reported once per change', () async {
    final room = InstantRoom(me: 'me')..localLevel = 0.4;

    roster.update(room);
    roster.update(room);
    room.localLevel = 0.7;
    roster.update(room);
    await settle();

    expect(levels, [0.4, 0.7]);
  });

  test('a restarting transport leaves the roster alone and zeroes the level',
      () async {
    final room = InstantRoom(me: 'me')..localLevel = 0.4;
    roster.update(room);
    reconnecting = true;

    roster.update(room);
    await settle();

    expect(roster.participants.map((p) => p.identity), ['me']);
    expect(emitted, hasLength(1));
    expect(levels, [0.4, 0.0]);
  });

  test('setting the roster empty drops your level with the people', () async {
    final room = InstantRoom(me: 'me')..localLevel = 0.4;
    roster.update(room);

    roster.set(const []);
    await settle();

    expect(roster.participants, isEmpty);
    expect(levels, [0.4, 0.0]);
  });

  group('the server saying someone left', () {
    List<String> shown() => [for (final p in roster.participants) p.identity];

    PeopleRoom withBob() => PeopleRoom()..people['bob'] = FakePeer('bob');

    test('hides them while the room still lists them', () {
      final room = withBob();
      roster.update(room);

      roster.leftByServer('bob');
      roster.update(room);

      expect(shown(), ['me']);
      expect(refreshes, 1);
    });

    test('forgets them once the room drops them, so a later join shows', () {
      final room = withBob();
      roster.leftByServer('bob');
      room.people.remove('bob');
      roster.update(room);

      room.people['bob'] = FakePeer('bob');
      roster.update(room);

      expect(shown(), ['me', 'bob']);
    });

    test('ends at their next join', () {
      final room = withBob();
      roster.leftByServer('bob');
      roster.update(room);

      roster.joinedByServer('bob');
      roster.update(room);

      expect(shown(), ['me', 'bob']);
    });

    test('lasts no longer than the hold while the room keeps listing them', () {
      fakeAsync((clock) {
        final room = withBob();
        roster.leftByServer('bob');
        roster.update(room);
        clock.elapse(kServerLeaveHold - const Duration(milliseconds: 1));
        roster.update(room);
        expect(shown(), ['me']);

        clock.elapse(const Duration(milliseconds: 1));
        roster.update(room);

        expect(shown(), ['me', 'bob']);
        expect(refreshes, 2);
        // The emits above were queued in this zone; the stream cannot close over them otherwise.
        clock.flushMicrotasks();
      });
    });

    test('never hides you', () {
      final room = withBob();
      roster.leftByServer('me');
      roster.update(room);

      expect(shown(), ['me', 'bob']);
    });

    test('is forgotten when the call ends', () {
      final room = withBob();
      roster.leftByServer('bob');
      roster.cancelHold();
      roster.update(room);

      expect(shown(), ['me', 'bob']);
    });
  });

  group('a full restart', () {
    PeopleRoom withBob() => PeopleRoom()..people['bob'] = FakePeer('bob');
    CallPresence? bob() => roster.participants
        .where((p) => p.identity == 'bob')
        .firstOrNull
        ?.presence;

    test('keeps who was shown, marked unconfirmed until the room lists them',
        () {
      final room = withBob();
      roster.update(room);
      expect(bob(), CallPresence.live);

      reconnecting = true;
      room.people.clear();
      roster.update(room);
      expect(bob(), CallPresence.unconfirmed);

      room.people['bob'] = FakePeer('bob');
      roster.update(room);
      expect(bob(), CallPresence.live);
    });

    test('someone already back is live while another is still held', () {
      final room = withBob()..people['cy'] = FakePeer('cy');
      roster.update(room);
      reconnecting = true;
      room.people.clear();
      roster.update(room);
      expect(bob(), CallPresence.unconfirmed);

      room.people['bob'] = FakePeer('bob');
      roster.update(room);

      expect(bob(), CallPresence.live);
      expect(
        roster.participants.firstWhere((p) => p.identity == 'cy').presence,
        CallPresence.unconfirmed,
      );
    });

    test('drops someone the server saw leave instead of holding them', () {
      final room = withBob();
      roster.update(room);
      reconnecting = true;
      room.people.clear();

      roster.leftByServer('bob');
      roster.update(room);

      expect(bob(), isNull);
    });
  });

  test('a change in sensitivity asks the session for a refresh', () {
    roster.setSensitivity(0.3);
    roster.setSensitivity(7);

    expect(refreshes, 2);
  });
}
