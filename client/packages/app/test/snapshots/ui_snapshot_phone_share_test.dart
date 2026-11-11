// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Phone screen share and video watching: the call stage with a share, the
/// full screen video, the local "you are sharing" state and the mini-player,
/// at a normal, a landscape and a small phone. PNGs only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/phone_landscape.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/call_mini_player_harness.dart';
import '../features/voice/voice_snapshot_fixtures.dart';
import '../ui_snapshot_support.dart';

const _me = VoiceParticipant(
  identity: 'user-nick',
  name: 'Nick',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
);
const _meSharing = VoiceParticipant(
  identity: 'user-nick',
  name: 'Nick',
  isLocal: true,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);
const _ada = VoiceParticipant(
  identity: 'user-ada',
  name: 'Ada',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: true,
);
const _bob = VoiceParticipant(
  identity: 'user-bob',
  name: 'Bob',
  isLocal: false,
  isSpeaking: false,
  isMuted: false,
  isScreenSharing: false,
  isCameraOn: true,
);

const _sizes = <String, Size>{
  'portrait': Size(390, 844),
  'landscape': Size(844, 390),
  'small': Size(360, 640),
};

List<Override> _call(
  List<VoiceParticipant> people, {
  bool sharing = false,
  bool awaiting = false,
}) => [
  voiceControllerProvider.overrideWith(
    (ref) => SnapshotVoiceController(
      ref,
      connectedCallState.copyWith(
        participants: people,
        screenSharing: sharing,
        awaitingBroadcast: awaiting,
      ),
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

Future<void> _resize(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final MapEntry(key: sizeName, value: size) in _sizes.entries) {
    for (final theme in ['dark', 'light']) {
      testWidgets(
        'call watching a share $sizeName $theme',
        (tester) => _onIPhone(
          () => renderSurface(
            tester,
            '/channels/c-main',
            'phone-portrait',
            theme,
            'phone-share-call-watch-$sizeName-$theme',
            overrides: _call(const [_me, _ada, _bob]),
            allowNoText: true,
            afterSettle: (t) => _resize(t, size),
          ),
        ),
      );
      testWidgets(
        'call sharing $sizeName $theme',
        (tester) => _onIPhone(
          () => renderSurface(
            tester,
            '/channels/c-main',
            'phone-portrait',
            theme,
            'phone-share-call-local-$sizeName-$theme',
            overrides: _call(const [_meSharing, _bob], sharing: true),
            allowNoText: true,
            afterSettle: (t) => _resize(t, size),
          ),
        ),
      );
      testWidgets(
        'call awaiting broadcast $sizeName $theme',
        (tester) => _onIPhone(
          () => renderSurface(
            tester,
            '/channels/c-main',
            'phone-portrait',
            theme,
            'phone-share-call-await-$sizeName-$theme',
            overrides: _call(const [_me, _bob], awaiting: true),
            allowNoText: true,
            afterSettle: (t) => _resize(t, size),
          ),
        ),
      );
      for (final kind in FullscreenVideoKind.values) {
        testWidgets(
          'fullscreen ${kind.name} $sizeName $theme',
          (tester) => _onIPhone(
            () => renderSurface(
              tester,
              '/channels/c-main',
              'phone-portrait',
              theme,
              'phone-share-full-${kind.name}-$sizeName-$theme',
              overrides: _call(const [_me, _ada, _bob]),
              allowNoText: true,
              afterSettle: (t) async {
                await _resize(t, size);
                final ctx = t.element(find.text('main').first);
                final share = kind == FullscreenVideoKind.screenShare;
                unawaited(
                  showFullscreenVideo(
                    ctx,
                    identity: share ? 'user-ada' : 'user-bob',
                    label: share ? "Ada's screen" : 'Bob',
                    kind: kind,
                  ),
                );
                await t.pump();
                await t.pump(const Duration(milliseconds: 400));
              },
            ),
          ),
        );
      }
      if (theme == 'dark') {
        for (final mode in ['dock', 'zoom']) {
          testWidgets(
            'fullscreen share $mode $sizeName',
            (tester) => _onIPhone(
              () => renderSurface(
                tester,
                '/channels/c-main',
                'phone-portrait',
                theme,
                'phone-share-full-$mode-$sizeName-$theme',
                overrides: [
                  ..._call(const [_me, _ada, _bob]),
                  portraitLockedPhoneProvider.overrideWith((ref) => true),
                ],
                allowNoText: true,
                afterSettle: (t) async {
                  await _resize(t, size);
                  final ctx = t.element(find.text('main').first);
                  unawaited(
                    showFullscreenVideo(
                      ctx,
                      identity: 'user-ada',
                      label: "Ada's screen",
                      kind: FullscreenVideoKind.screenShare,
                    ),
                  );
                  await t.pump();
                  await t.pump(const Duration(milliseconds: 400));
                  if (mode == 'dock') {
                    await t.tap(find.byTooltip('Show controls'));
                  } else {
                    await t.sendKeyEvent(LogicalKeyboardKey.equal);
                    await t.sendKeyEvent(LogicalKeyboardKey.equal);
                  }
                  await t.pump();
                  await t.pump(const Duration(milliseconds: 400));
                },
              ),
            ),
          );
        }
      }
      testWidgets(
        'mini player $sizeName $theme',
        (tester) => _onIPhone(() async {
          final ctx = await pumpMini(
            tester,
            location: '/channels/c-general',
            voice: miniCall(const [_me, remoteShare]),
            size: size,
            brightness: theme == 'dark' ? Brightness.dark : Brightness.light,
          );
          await settleMini(tester);
          await writeSnapshot(tester, 'phone-share-mini-$sizeName-$theme');
          await ctx.done();
        }),
      );
    }
  }
}
