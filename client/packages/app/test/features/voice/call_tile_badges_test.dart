// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call tile draws one badge per state, so a sharer who is muted shows both,
/// and a name over live video sits on a pill rather than bare on the picture.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/call_tile_badges.dart';
import 'package:slimm_app/src/features/voice/widgets/video_label_pill.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';

VoiceParticipant _who({
  bool muted = false,
  bool deafened = false,
  bool sharing = false,
  bool camera = false,
}) => VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isSpeaking: false,
  isMuted: muted,
  isLocal: false,
  isScreenSharing: sharing,
  isDeafened: deafened,
  isCameraOn: camera,
);

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Align(alignment: Alignment.topLeft, child: child),
    ),
  ),
);

Future<void> _pumpTile(WidgetTester tester, VoiceParticipant who) =>
    tester.pumpWidget(
      _app(CallParticipantTile(participant: who, width: kCallTileMinWidth)),
    );

void main() {
  setUpAll(loadRealFonts);

  group('state badges', () {
    testWidgets('a muted sharer shows both the mute and the share badge', (
      tester,
    ) async {
      await _pumpTile(tester, _who(muted: true, sharing: true));
      expect(find.byKey(mutedBadgeKey), findsOneWidget);
      expect(find.byKey(sharingBadgeKey), findsOneWidget);
    });

    testWidgets('a sharer with a live mic shows only the share badge', (
      tester,
    ) async {
      await _pumpTile(tester, _who(sharing: true));
      expect(find.byKey(sharingBadgeKey), findsOneWidget);
      expect(find.byIcon(AppIcons.mic), findsNothing);
      expect(find.byKey(mutedBadgeKey), findsNothing);
    });

    testWidgets('someone talking and not sharing shows a live mic', (
      tester,
    ) async {
      await _pumpTile(tester, _who());
      expect(find.byIcon(AppIcons.mic), findsOneWidget);
      expect(find.byKey(sharingBadgeKey), findsNothing);
    });

    testWidgets('all three badges keep clear of each other and the avatar', (
      tester,
    ) async {
      await _pumpTile(tester, _who(muted: true, deafened: true, sharing: true));
      final badges = [
        tester.getRect(find.byKey(deafenedBadgeKey)),
        tester.getRect(find.byKey(mutedBadgeKey)),
        tester.getRect(find.byKey(sharingBadgeKey)),
      ];
      final avatar = tester.getRect(find.byKey(callTileAvatarKey));
      for (final badge in badges) {
        expect(badge.overlaps(avatar), isFalse);
      }
      for (var i = 0; i < badges.length; i++) {
        for (var j = i + 1; j < badges.length; j++) {
          expect(badges[i].overlaps(badges[j]), isFalse);
        }
      }
      expect(tester.takeException(), isNull);
    });

    test('the badge count follows deafened, mic and sharing', () {
      expect(tileBadgeCount(_who()), 1);
      expect(tileBadgeCount(_who(sharing: true)), 1);
      expect(tileBadgeCount(_who(muted: true, sharing: true)), 2);
      expect(
        tileBadgeCount(_who(muted: true, sharing: true, deafened: true)),
        3,
      );
    });

    test('three badges reach the avatar sooner than one', () {
      final one = _who();
      final three = _who(muted: true, sharing: true, deafened: true);
      expect(badgesReachAvatar(160, 56, one), isFalse);
      expect(badgesReachAvatar(160, 56, three), isTrue);
    });
  });

  group('name labels over video', () {
    testWidgets('a camera tile puts its name on a pill', (tester) async {
      await tester.pumpWidget(
        _app(
          CallParticipantTile(
            participant: _who(camera: true),
            cameraView: const ColoredBox(color: Color(0xFF223344)),
          ),
        ),
      );
      final pill = tester.getRect(find.byKey(videoLabelPillKey));
      final name = tester.getRect(find.text('Bob'));
      expect(pill.contains(name.topLeft), isTrue);
      expect(pill.contains(name.bottomRight), isTrue);
    });

    testWidgets('an avatar tile has no pill', (tester) async {
      await _pumpTile(tester, _who());
      expect(find.byKey(videoLabelPillKey), findsNothing);
    });
  });
}
