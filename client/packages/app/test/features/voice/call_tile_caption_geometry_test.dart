// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tile's state caption never paints over its avatar, at any height the stage produces.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/video_pause.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/features/voice/widgets/call_tile_badges.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: true,
);

Widget _tile(double width, double height, VoiceParticipant p) => ProviderScope(
  overrides: [
    userProfileProvider('u-ada').overrideWith((ref) async => null),
    localPreviewPausedProvider.overrideWithValue(false),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: CallParticipantTile(
          participant: p,
          width: width,
          height: height,
          cameraView: const SizedBox.expand(),
        ),
      ),
    ),
  ),
);

void main() {
  for (final height in [72.0, 80.0, 96.0, 110.0, 130.0, 160.0, 200.0]) {
    testWidgets('the camera caption clears the avatar in a ${height}dp tile', (
      tester,
    ) async {
      await tester.pumpWidget(_tile(170, height, _ada));
      await tester.pump();
      final caption = tester.getRect(find.byKey(cameraStartingKey));
      final avatar = tester.getRect(find.byKey(callTileAvatarKey));
      final tile = tester.getRect(find.byType(CallParticipantTile));
      expect(caption.overlaps(avatar), isFalse, reason: '$caption vs $avatar');
      expect(tile.inflate(0.5).contains(caption.topLeft), isTrue);
      expect(tile.inflate(0.5).contains(caption.bottomRight), isTrue);
      expect(tile.inflate(0.5).contains(avatar.topLeft), isTrue);
      expect(tile.inflate(0.5).contains(avatar.bottomRight), isTrue);
    });
  }
}
