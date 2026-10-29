// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sharer's overlay: opt-in, whole-screen shares only, and torn down the
/// moment any of that stops being true.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_board.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_consent.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';
import '../voice/voice_controller_harness.dart';

class _Driven extends VoiceController {
  _Driven(super.ref, VoiceState initial) : super(session: FakeSession()) {
    state = initial;
  }

  void set(VoiceState next) => state = next;
}

class _Sync extends NoopSyncController {
  _Sync(super.ref);

  final events = StreamController<api.ServerEvent>.broadcast();
  final sent = <({String kind, bool allowed, double? aspect, String target})>[];

  @override
  Stream<api.ServerEvent> get liveEvents => events.stream;

  @override
  void notifyCanvasScreenAnnotation(
    String channelId,
    String targetUserId,
    String kind, {
    String? annotationId,
    List<double> points = const [],
    String? color,
    String? text,
    bool ended = false,
    bool allowed = false,
    double? aspect,
  }) => sent.add((
    kind: kind,
    allowed: allowed,
    aspect: aspect,
    target: targetUserId,
  ));
}

class _FakeOverlay implements ScreenOverlay {
  final shown = <int>[];
  final draws = <List<OverlayShape>>[];
  var hides = 0;

  @override
  Future<OverlaySupport> support() async => const OverlaySupport.unsupported();
  @override
  Future<bool> show(int monitor) async {
    shown.add(monitor);
    return true;
  }

  @override
  Future<void> draw(List<OverlayShape> shapes) async => draws.add(shapes);
  @override
  Future<void> hide() async => hides++;
}

VoiceParticipant _me() => const VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: true,
);

final _sharing = VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  screenSharing: true,
  participants: [_me()],
);

const _monitors = [
  OverlayMonitor(x: 0, y: 0, width: 1920, height: 1080, primary: true),
  OverlayMonitor(x: 1920, y: 0, width: 1280, height: 800, primary: false),
];

class _Rig {
  _Rig({
    bool allow = true,
    bool supported = true,
    VoiceState? initial,
    ScreenShareSource? source,
  }) {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.screen_share_allow_annotations': allow,
    });
    container = ProviderContainer(
      overrides: [
        screenOverlayProvider.overrideWithValue(overlay),
        screenOverlaySupportProvider.overrideWith(
          (ref) async => supported
              ? const OverlaySupport(supported: true, monitors: _monitors)
              : const OverlaySupport.unsupported(),
        ),
        voiceControllerProvider.overrideWith(
          (ref) => voice = _Driven(ref, initial ?? _sharing),
        ),
        syncControllerProvider.overrideWith((ref) => sync = _Sync(ref)),
      ],
    );
    container.read(voiceSettingsControllerProvider);
    container.read(voiceControllerProvider);
    voice.share.lastShareSource = source;
    container.read(syncControllerProvider);
    container.read(screenOverlayControllerProvider);
  }

  final overlay = _FakeOverlay();
  late final ProviderContainer container;
  late final _Driven voice;
  late final _Sync sync;

  bool get active => container.read(screenOverlayControllerProvider).active;

  void annotate({
    String target = 'me',
    List<double> points = const [0.1, 0.1, 0.5, 0.5],
    bool ended = true,
  }) => sync.events.add(
    api.CanvasScreenAnnotation(
      channelId: 'call',
      userId: 'viewer',
      targetUserId: target,
      kind: 'stroke',
      annotationId: 'a1',
      points: points,
      color: 'blue',
      ended: ended,
      allowed: false,
    ),
  );
}

void main() {
  test('off by default: nothing is shown and nothing is announced', () {
    fakeAsync((async) {
      final rig = _Rig(allow: false);
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
        final rig = _Rig();
        async.flushMicrotasks();
        expect(rig.active, isTrue);
        expect(rig.overlay.shown, [0]);
        final consent = rig.sync.sent.single;
        expect(
          (consent.kind, consent.allowed, consent.target),
          ('consent', true, 'me'),
        );
        expect(consent.aspect, closeTo(1920 / 1080, 1e-9));
      });
    },
  );

  test('consent is repeated while the overlay stays up', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();
      async.elapse(consentHeartbeat * 3);
      expect(rig.sync.sent.length, 4);
    });
  });

  test('an unsupported desktop never opens it', () {
    fakeAsync((async) {
      final rig = _Rig(supported: false);
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
    });
  });

  test('a window share never opens it', () {
    fakeAsync((async) {
      final rig = _Rig(
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
      final rig = _Rig(initial: _sharing.copyWith(screenSharing: false));
      async.flushMicrotasks();
      expect(rig.active, isFalse);
    });
  });

  test('stopping the share closes the overlay and withdraws consent', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();
      rig.voice.set(_sharing.copyWith(screenSharing: false));
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.hides, 1);
      expect(rig.sync.sent.last.allowed, isFalse);
    });
  });

  test('turning it off from the indicator closes the overlay', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();
      unawaited(
        rig.container.read(screenOverlayControllerProvider.notifier).turnOff(),
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
        final rig = _Rig();
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

  test('a mark over somebody else\'s screen paints nothing', () {
    fakeAsync((async) {
      final rig = _Rig();
      async.flushMicrotasks();
      rig.annotate(target: 'someone-else');
      async.elapse(const Duration(seconds: 1));
      expect(rig.overlay.draws, isEmpty);
    });
  });

  test('a mark that arrives while the setting is off paints nothing', () {
    fakeAsync((async) {
      final rig = _Rig(allow: false);
      async.flushMicrotasks();
      rig.annotate();
      async.elapse(const Duration(seconds: 1));
      expect(rig.overlay.draws, isEmpty);
    });
  });

  test(
    'off Windows a capturer screen number is not trusted, so the primary monitor is used',
    () {
      fakeAsync((async) {
        final rig = _Rig(
          source: const ScreenShareSource(id: 's', name: 'Screen 2'),
        );
        async.flushMicrotasks();
        expect(rig.overlay.shown, [0]);
      });
    },
  );
}
