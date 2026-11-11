// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Windows the overlay follows the capturer's own screen order, and the
/// call panel keeps its own window so a whole-screen share does not remove it.
library;

import 'dart:ui';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_mapping.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

/// The VM's two monitors: EnumDisplayMonitors lists the non-primary DISPLAY1 first, DXGI the primary DISPLAY2 first.
const _display1 = OverlayMonitor(
  x: 1024,
  y: 0,
  width: 1280,
  height: 800,
  primary: false,
  deviceIndex: 0,
  capturePosition: 1,
);
const _display2 = OverlayMonitor(
  x: 0,
  y: 0,
  width: 1024,
  height: 768,
  primary: true,
  deviceIndex: 1,
  capturePosition: 0,
);
const _enumOrder = [_display1, _display2];

VoiceParticipant _me() => const VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: true,
);

VoiceParticipant _web() => const VoiceParticipant(
  identity: 'web',
  name: 'web',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

VoiceState _call({bool sharing = false}) => VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  screenSharing: sharing,
  participants: [_me(), _web()],
);

void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

void main() {
  group('pickSharedMonitors on Windows', () {
    test('the source id names the monitor, whatever the enumeration order', () {
      expect(pickSharedMonitors(_enumOrder, sourceId: '1'), [1]);
      expect(pickSharedMonitors(_enumOrder, sourceId: '0'), [0]);
    });

    test('Screen N is the capture position, not the enumeration index', () {
      expect(pickSharedMonitors(_enumOrder, screenNumber: 1), [1]);
      expect(pickSharedMonitors(_enumOrder, screenNumber: 2), [0]);
    });

    test('the id wins over a label that disagrees', () {
      expect(pickSharedMonitors(_enumOrder, sourceId: '0', screenNumber: 1), [
        0,
      ]);
    });

    test('the GDI order, where position follows the active devices', () {
      const gdi = [
        OverlayMonitor(
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          primary: true,
          deviceIndex: 0,
          capturePosition: 0,
        ),
        OverlayMonitor(
          x: 1920,
          y: 0,
          width: 1280,
          height: 800,
          primary: false,
          deviceIndex: 2,
          capturePosition: 1,
        ),
      ];
      expect(pickSharedMonitors(gdi, sourceId: '2', screenNumber: 2), [1]);
      expect(pickSharedMonitors(gdi, screenNumber: 2), [1]);
    });

    test(
      'an id or number nothing matches falls back to the captured shape',
      () {
        expect(
          pickSharedMonitors(
            _enumOrder,
            sourceId: '9',
            screenNumber: 9,
            capturedSize: const Size(1024, 768),
          ),
          [1],
        );
        expect(pickSharedMonitors(_enumOrder, sourceId: 'abc'), [0, 1]);
      },
    );

    test('a runner that reports no capture order keeps the old numbering', () {
      final plain = [
        const OverlayMonitor(
          x: 0,
          y: 0,
          width: 1920,
          height: 1080,
          primary: true,
        ),
        const OverlayMonitor(
          x: 1920,
          y: 0,
          width: 1280,
          height: 800,
          primary: false,
        ),
      ];
      expect(pickSharedMonitors(plain, screenNumber: 2), [1]);
    });
  });

  test('sharing Screen 1 covers the primary monitor, not the first listed', () {
    fakeAsync((async) {
      final rig = OverlayRig(
        windows: true,
        monitors: _enumOrder,
        source: const ScreenShareSource(id: '1', name: 'Screen 1'),
      );
      async.flushMicrotasks();
      expect(rig.overlay.shown, [
        [1],
      ]);
    });
  });

  group('the call panel while sharing a whole screen', () {
    OverlayRig rig({required bool windows, bool allow = false}) => OverlayRig(
      allow: allow,
      callOverlay: true,
      windows: windows,
      initial: _call(sharing: true),
      source: const ScreenShareSource(id: '1', name: 'Screen 1'),
    );

    test('stays up on Windows, in its own window', () {
      fakeAsync((async) {
        final r = rig(windows: true);
        async.flushMicrotasks();
        expect(r.overlay.panels, isNotEmpty);
        expect(r.overlay.panels.last, isNotNull);
        expect(r.overlay.shown, isEmpty);
        expect(r.overlay.hides, 0);
      });
    });

    test('and the drawing window opens beside it without dropping it', () {
      fakeAsync((async) {
        final r = rig(windows: true, allow: true);
        async.flushMicrotasks();
        expect(r.active, isTrue);
        expect(r.overlay.panels.last, isNotNull);
        expect(r.overlay.panels.where((p) => p == null), isEmpty);
        r.voice.set(_call());
        _settle(async);
        expect(r.active, isFalse);
        expect(r.overlay.panels.last, isNotNull);
      });
    });

    test('is hidden on Linux, which cannot keep it out of the stream', () {
      fakeAsync((async) {
        final r = rig(windows: false);
        async.flushMicrotasks();
        expect(r.overlay.panels, isEmpty);
      });
    });
  });
}
