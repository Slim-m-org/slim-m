// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sharer's overlay: opt-in, whole-screen shares only, and torn down the
/// moment any of that stops being true.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_consent.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_design_system/design_system.dart' show AppToastSeverity;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/voice_controller_harness.dart';
import 'overlay_rig.dart';

void main() {
  _lateProbeTest();
  test('off by default: nothing is shown and nothing is announced', () {
    fakeAsync((async) {
      final rig = OverlayRig(allow: false);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
      expect(rig.sync.sent, isEmpty);
    });
  });

  test(
    'allowed and sharing a screen: the overlay opens and consent is announced',
    () {
      fakeAsync((async) {
        final rig = OverlayRig();
        async.flushMicrotasks();
        expect(rig.active, isTrue);
        expect(rig.overlay.shown, [
          [0, 1],
        ]);
        final consent = rig.sync.sent.single;
        expect(
          (consent.kind, consent.allowed, consent.target),
          ('consent', true, 'me'),
        );
        expect(consent.aspect, isNull);
      });
    },
  );

  test('the monitor the portal names is the one covered', () {
    fakeAsync((async) {
      final rig = OverlayRig(portal: (x: 1920, y: 0, width: 1280, height: 800));
      async.flushMicrotasks();
      expect(rig.overlay.shown, [
        [1],
      ]);
    });
  });

  test('a known capture size covers only the monitor of that shape', () {
    fakeAsync((async) {
      localShareCapturedSize.value = (width: 1280, height: 800);
      addTearDown(() => localShareCapturedSize.value = null);
      final rig = OverlayRig();
      async.flushMicrotasks();
      expect(rig.overlay.shown, [
        [1],
      ]);
      expect(rig.sync.sent.single.aspect, closeTo(1.6, 1e-9));
    });
  });

  test('consent is repeated while the overlay stays up', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      async.elapse(consentHeartbeat * 3);
      expect(rig.sync.sent.length, 4);
    });
  });

  test('an unsupported desktop never opens it', () {
    fakeAsync((async) {
      final rig = OverlayRig(supported: false);
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
    });
  });

  test('a window share never opens it', () {
    fakeAsync((async) {
      final rig = OverlayRig(
        source: const ScreenShareSource(
          id: 'w',
          name: 'Editor',
          isWindow: true,
        ),
      );
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
    });
  });

  test('not sharing: nothing is shown', () {
    fakeAsync((async) {
      final rig = OverlayRig(
        initial: rigSharing.copyWith(screenSharing: false),
      );
      async.flushMicrotasks();
      expect(rig.active, isFalse);
    });
  });

  test('opening the overlay says so in one toast and no banner', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      final toasts = rig.container.read(toastsProvider);
      expect(toasts.map((t) => t.message), [
        'Viewers can draw on your screen.',
      ]);
      expect(toasts.single.severity, AppToastSeverity.info);
      async.elapse(ToastsController.defaultDuration);
    });
  });

  test('stopping the share closes the overlay and withdraws consent', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.voice.set(rigSharing.copyWith(screenSharing: false));
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.hides, 1);
      expect(rig.sync.sent.last.allowed, isFalse);
    });
  });

  test('turning the setting off closes the overlay', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      unawaited(
        rig.container
            .read(voiceSettingsControllerProvider.notifier)
            .setScreenShareAllowAnnotations(false),
      );
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.hides, 1);
      expect(rig.sync.sent.last.allowed, isFalse);
    });
  });

  test(
    'a viewer mark over my screen is painted, then fades to an empty overlay',
    () {
      fakeAsync((async) {
        final rig = OverlayRig();
        async.flushMicrotasks();
        rig.annotate();
        async.elapse(overlayFrameInterval * 2);
        expect(rig.overlay.draws.last.single, isA<OverlayStroke>());

        async.elapse(
          annotationHold + annotationFade + overlayFrameInterval * 2,
        );
        expect(rig.overlay.draws.last, isEmpty);
        final drawn = rig.overlay.draws.length;
        async.elapse(const Duration(seconds: 2));
        expect(rig.overlay.draws.length, drawn);
      });
    },
  );

  test('a mark held at full strength is painted once, not every frame', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.annotate();
      async.elapse(overlayFrameInterval * 2);
      expect(rig.overlay.draws, hasLength(1));

      async.elapse(annotationHold - overlayFrameInterval * 4);
      expect(rig.overlay.draws, hasLength(1));
    });
  });

  test('a mark that grows is painted again with its new points', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.annotate(ended: false);
      async.elapse(overlayFrameInterval * 2);
      rig.annotate(points: const [0.6, 0.6], ended: false);
      async.elapse(overlayFrameInterval * 2);
      expect(rig.overlay.draws, hasLength(2));
      final stroke = rig.overlay.draws.last.single as OverlayStroke;
      expect(stroke.points, [0.1, 0.1, 0.5, 0.5, 0.6, 0.6]);
    });
  });

  test('a mark over somebody else\'s screen paints nothing', () {
    fakeAsync((async) {
      final rig = OverlayRig();
      async.flushMicrotasks();
      rig.annotate(target: 'someone-else');
      async.elapse(const Duration(seconds: 1));
      expect(rig.overlay.draws, isEmpty);
    });
  });

  test('a mark that arrives while the setting is off paints nothing', () {
    fakeAsync((async) {
      final rig = OverlayRig(allow: false);
      async.flushMicrotasks();
      rig.annotate();
      async.elapse(const Duration(seconds: 1));
      expect(rig.overlay.draws, isEmpty);
    });
  });

  test(
    'off Windows a capturer screen number is not trusted, so every monitor is covered',
    () {
      fakeAsync((async) {
        final rig = OverlayRig(
          source: const ScreenShareSource(id: 's', name: 'Screen 2'),
        );
        async.flushMicrotasks();
        expect(rig.overlay.shown, [
          [0, 1],
        ]);
      });
    },
  );
}

void _lateProbeTest() {
  test(
    'a probe that read unsupported before the window was up is asked again on join',
    () {
      fakeAsync((async) {
        SharedPreferences.setMockInitialValues({
          'slimm.voice.screen_share_allow_annotations': true,
        });
        var probes = 0;
        late FixedVoiceController voice;
        final container = ProviderContainer(
          overrides: [
            screenOverlayProvider.overrideWithValue(FakeOverlay()),
            portalSharedMonitorProvider.overrideWithValue(() async => null),
            screenOverlaySupportProvider.overrideWith((ref) async {
              probes++;
              return probes == 1
                  ? const OverlaySupport.unsupported()
                  : const OverlaySupport(
                      supported: true,
                      monitors: rigMonitors,
                    );
            }),
            voiceControllerProvider.overrideWith(
              (ref) => voice = FixedVoiceController(ref, const VoiceState()),
            ),
            syncControllerProvider.overrideWith((ref) => RigSync(ref)),
          ],
        );
        container.read(voiceSettingsControllerProvider);
        container.read(voiceControllerProvider);
        container.read(syncControllerProvider);
        container.read(screenOverlayControllerProvider);
        async.flushMicrotasks();
        expect(container.read(screenOverlaySupportedProvider), isFalse);
        voice.set(rigSharing);
        async.elapse(const Duration(seconds: 1));
        expect(container.read(screenOverlaySupportedProvider), isTrue);
        expect(container.read(screenOverlayControllerProvider).active, isTrue);
      });
    },
  );
}
