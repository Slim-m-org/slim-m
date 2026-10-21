// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Other people see a deafened listener on their tile and in the rail, and the
/// deafening client tells the call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_voice_participants.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

VoiceParticipant _who({bool deafened = false, bool muted = false}) =>
    VoiceParticipant(
      identity: 'user-bob',
      name: 'Bob',
      isSpeaking: false,
      isMuted: muted,
      isLocal: false,
      isScreenSharing: false,
      isDeafened: deafened,
    );

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  group('showing', () {
    testWidgets('a deafened tile shows the glyph beside the mute badge', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          CallParticipantTile(
            participant: _who(deafened: true, muted: true),
            width: kCallTileMinWidth,
          ),
        ),
      );

      expect(find.byKey(deafenedBadgeKey), findsOneWidget);
      expect(find.byIcon(AppIcons.micOff), findsOneWidget);
    });

    testWidgets('at the narrowest tile the badges stay clear of the avatar', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          CallParticipantTile(
            participant: _who(deafened: true, muted: true),
            width: kCallTileMinWidth,
          ),
        ),
      );

      final avatar = tester.getRect(find.byType(UserAvatar));
      for (final badge in [
        find.byKey(deafenedBadgeKey),
        find.byIcon(AppIcons.micOff),
      ]) {
        expect(tester.getRect(badge).overlaps(avatar), isFalse);
      }
    });

    testWidgets('a tile of someone who can hear shows no glyph', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          CallParticipantTile(participant: _who(), width: kCallTileMinWidth),
        ),
      );

      expect(find.byKey(deafenedBadgeKey), findsNothing);
    });

    testWidgets('the rail roster row shows it next to mute', (tester) async {
      await tester.pumpWidget(
        _app(
          RailParticipantList(
            participants: [_who(deafened: true, muted: true)],
            channelId: 'c1',
          ),
        ),
      );

      expect(find.byIcon(AppIcons.headphonesOff), findsOneWidget);
      expect(find.byIcon(AppIcons.micOff), findsOneWidget);
    });

    testWidgets('the rail roster row is plain for someone who can hear', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(RailParticipantList(participants: [_who()], channelId: 'c1')),
      );

      expect(find.byIcon(AppIcons.headphonesOff), findsNothing);
    });
  });

  group('sending', () {
    final harness = VoiceHarness();
    tearDown(harness.dispose);

    test('deafening and undeafening each tell the call', () async {
      final puts = <String>[];
      final controller = harness.controllerWith(
        FakeSession(),
        voiceApi(
          onRequest: (r) {
            if (r.url.path.endsWith('/voice/deafened')) {
              puts.add('${r.method} ${r.url.path} ${r.body}');
            }
          },
        ),
      );
      await controller.join('lounge');

      await controller.toggleDeafen();
      await controller.toggleDeafen();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(puts, [
        'PUT /channels/lounge/voice/deafened {"deafened":true}',
        'PUT /channels/lounge/voice/deafened {"deafened":false}',
      ]);
    });
  });
}
