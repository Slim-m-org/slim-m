// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster a call reports: emitted only on a real change, with your own level fed apart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/voice_roster.dart';

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

  test('a change in sensitivity asks the session for a refresh', () {
    roster.setSensitivity(0.3);
    roster.setSensitivity(7);

    expect(refreshes, 2);
  });
}
