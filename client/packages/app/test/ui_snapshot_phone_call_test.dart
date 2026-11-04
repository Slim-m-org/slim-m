// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real shell on an iPhone (390x844, iOS target platform) in a voice
/// channel call: alone, and with a share the viewer stopped watching.
/// PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/share_watch.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'features/voice/voice_snapshot_fixtures.dart';
import 'ui_snapshot_support.dart';

const _me = VoiceParticipant(
  identity: 'user-nick',
  name: 'Nick',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);

const _ada = VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);

List<Override> _call(List<VoiceParticipant> people) => [
  voiceControllerProvider.overrideWith(
    (ref) => SnapshotVoiceController(
      ref,
      connectedCallState.copyWith(participants: people),
    ),
  ),
];

Future<void> _onIPhone(Future<void> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets(
    'iphone alone in a voice channel call',
    (tester) => _onIPhone(() async {
      await renderSurface(
        tester,
        '/channels/c-main',
        'phone-portrait',
        'dark',
        'iphone-call-alone',
        overrides: _call(const [_me]),
        allowNoText: true,
      );
    }),
  );

  testWidgets(
    'iphone call with a hidden share has no banner',
    (tester) => _onIPhone(() async {
      await renderSurface(
        tester,
        '/channels/c-main',
        'phone-portrait',
        'dark',
        'iphone-call-share-hidden',
        overrides: [
          ..._call(const [_me, _ada]),
          shareWatchProvider.overrideWith(
            (ref) => ShareWatchController((_) {})..stop('user-ada'),
          ),
        ],
        allowNoText: true,
      );
    }),
  );
}
