// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's list of who is in the call against what this device's call delivered.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/voice/providers/call_roster_gap.dart';
import 'package:slimm_app/src/features/voice/widgets/call_gap_banner.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/call_stage_layout.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _me = 'u-bob';
final _t0 = DateTime(2026, 11, 18, 20, 17);

const _bob = api.VoiceRosterParticipant(
  userId: _me,
  displayName: 'Bob',
  thisDevice: true,
);
const _alice = api.VoiceRosterParticipant(
  userId: 'u-alice',
  displayName: 'Alice',
);

CallRosterGap _at(
  RosterGapTracker tracker,
  Duration after,
  List<api.VoiceRosterParticipant> server, {
  Set<String> shown = const {},
}) => tracker.observe(
  server: server,
  shown: shown,
  selfId: _me,
  now: _t0.add(after),
);

void main() {
  group('RosterGapTracker', () {
    test(
      'someone the server lists and the call never delivered shows once it holds',
      () {
        final tracker = RosterGapTracker();
        expect(_at(tracker, Duration.zero, [_bob, _alice]).connecting, isEmpty);
        expect(
          _at(tracker, const Duration(seconds: 5), [_bob, _alice]).connecting,
          isEmpty,
        );
        expect(_at(tracker, kRosterGapConfirm, [_bob, _alice]).connecting, [
          (id: 'u-alice', name: 'Alice'),
        ]);
      },
    );

    test('an ordinary join the call delivers in time never shows', () {
      final tracker = RosterGapTracker();
      _at(tracker, Duration.zero, [_bob, _alice]);
      final gap = _at(
        tracker,
        kRosterGapConfirm,
        [_bob, _alice],
        shown: {'u-alice'},
      );
      expect(gap, CallRosterGap.none);
    });

    test(
      'clears the moment the call delivers them, without waiting on the server',
      () {
        final tracker = RosterGapTracker();
        _at(tracker, Duration.zero, [_bob, _alice]);
        final gap = _at(tracker, kRosterGapConfirm, [_bob, _alice]);
        expect(tracker.forget(gap, {'u-alice'}).connecting, isEmpty);
      },
    );

    test('this device missing from the server list shows once it holds', () {
      final tracker = RosterGapTracker();
      expect(_at(tracker, Duration.zero, [_alice]).selfMissing, isFalse);
      expect(_at(tracker, kRosterGapConfirm, [_alice]).selfMissing, isTrue);
      expect(
        _at(tracker, kRosterGapConfirm * 2, [_bob, _alice]).selfMissing,
        isFalse,
      );
    });

    test('another device of this account is not this device', () {
      final tracker = RosterGapTracker();
      const elsewhere = api.VoiceRosterParticipant(
        userId: _me,
        displayName: 'Bob',
      );
      _at(tracker, Duration.zero, [elsewhere]);
      expect(_at(tracker, kRosterGapConfirm, [elsewhere]).selfMissing, isTrue);
    });
  });

  group('the stage', () {
    test('adds a connecting tile after everyone the call delivered', () {
      const me = VoiceParticipant(
        identity: _me,
        name: 'Bob',
        isSpeaking: false,
        isMuted: false,
        isLocal: true,
        isScreenSharing: false,
      );
      final staged = withPendingPeers([me], [(id: 'u-alice', name: 'Alice')]);
      expect(staged.map((p) => (p.identity, p.presence)), [
        (_me, CallPresence.live),
        ('u-alice', CallPresence.connecting),
      ]);
    });

    test('names one or two pending people and counts more', () {
      expect(pendingPeersLine(const []), isNull);
      expect(
        pendingPeersLine(const [(id: 'a', name: 'Alice')]),
        'Alice is in the call but not connected to you yet.',
      );
      expect(
        pendingPeersLine(const [
          (id: 'a', name: 'Alice'),
          (id: 'c', name: 'Cara'),
          (id: 'd', name: 'Dev'),
        ]),
        '3 people are in the call but not connected to you yet.',
      );
    });

    testWidgets(
      'a connecting tile says so, and a held one says it is reconnecting',
      (tester) async {
        final handle = tester.ensureSemantics();
        Widget tile(CallPresence presence) => CallParticipantTile(
          participant: VoiceParticipant(
            identity: 'u-alice',
            name: 'Alice',
            isSpeaking: false,
            isMuted: false,
            isLocal: false,
            isScreenSharing: false,
            presence: presence,
          ),
        );
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: buildTheme(Brightness.light, AppTokens.light),
              home: Scaffold(
                body: Row(
                  children: [
                    tile(CallPresence.connecting),
                    tile(CallPresence.unconfirmed),
                  ],
                ),
              ),
            ),
          ),
        );
        expect(find.bySemanticsLabel('Alice, connecting'), findsOneWidget);
        expect(
          find.bySemanticsLabel('Alice, reconnecting, microphone on'),
          findsOneWidget,
        );
        expect(find.text('Connecting'), findsOneWidget);
        expect(find.text('Reconnecting'), findsOneWidget);
        handle.dispose();
      },
    );
  });
}
