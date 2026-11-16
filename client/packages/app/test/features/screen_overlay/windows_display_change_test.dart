// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Windows the call panel stays up through a share started mid-call, and a
/// change to the monitor layout puts the panel and the drawing overlay back on
/// the screens they belong to instead of leaving them where the old layout was.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

const _main = OverlayMonitor(
  x: 0,
  y: 0,
  width: 1920,
  height: 1080,
  primary: true,
  deviceIndex: 0,
  capturePosition: 0,
);
const _side = OverlayMonitor(
  x: 1920,
  y: 0,
  width: 1280,
  height: 800,
  primary: false,
  deviceIndex: 1,
  capturePosition: 1,
);

/// A monitor plugged in to the left, which Windows lists first.
const _plugged = OverlayMonitor(
  x: -1024,
  y: 0,
  width: 1024,
  height: 768,
  primary: false,
  deviceIndex: 2,
  capturePosition: 2,
);

const _screen1 = ScreenShareSource(id: '0', name: 'Screen 1');
const _editor = ScreenShareSource(id: '263428', name: 'Editor', isWindow: true);

VoiceParticipant _me() => const VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

VoiceState _call({bool sharing = false}) => VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  screenSharing: sharing,
  participants: [_me()],
);

void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

OverlayRig _rig({
  bool allow = false,
  bool sharing = false,
  ScreenShareSource? source,
}) => OverlayRig(
  allow: allow,
  callOverlay: true,
  windows: true,
  initial: _call(sharing: sharing),
  source: source,
  monitors: const [_main, _side],
);

void main() {
  test('a share started mid-call never takes the panel down, whatever is '
      'shared and whether viewers may draw', () {
    fakeAsync((async) {
      final rig = _rig();
      _settle(async);
      expect(rig.overlay.panels.single, isNotNull);

      rig.voice.share.lastShareSource = _screen1;
      rig.voice.set(_call(sharing: true));
      _settle(async);
      final settings = rig.container.read(
        voiceSettingsControllerProvider.notifier,
      );
      settings.setScreenShareAllowAnnotations(true);
      _settle(async);
      expect(rig.active, isTrue);

      rig.voice.share.lastShareSource = _editor;
      rig.voice.set(_call());
      _settle(async);
      rig.voice.set(_call(sharing: true));
      _settle(async);
      expect(rig.overlay.windows.last, 263428);
      settings.setScreenShareAllowAnnotations(false);
      _settle(async);
      rig.voice.set(_call());
      _settle(async);

      expect(rig.active, isFalse);
      expect(rig.overlay.panels, everyElement(isNotNull));
    });
  });

  group('a monitor layout change', () {
    test('reopens the panel on the screen the app is on, at its new index', () {
      fakeAsync((async) {
        final rig = _rig();
        _settle(async);
        expect(rig.overlay.panels.single!.monitor, 0);

        rig.overlay.appMonitorIndex = 1;
        rig.changeDisplays(const [_plugged, _main, _side]);
        _settle(async);

        expect(rig.overlay.panels, hasLength(3));
        expect(rig.overlay.panels[1], isNull);
        expect(rig.overlay.panels.last!.monitor, 1);
      });
    });

    test('reopens the panel when only its own screen changed size', () {
      fakeAsync((async) {
        final rig = _rig();
        _settle(async);

        rig.changeDisplays(const [
          OverlayMonitor(
            x: 0,
            y: 0,
            width: 1280,
            height: 720,
            primary: true,
            deviceIndex: 0,
            capturePosition: 0,
          ),
          _side,
        ]);
        _settle(async);

        expect(rig.overlay.panels, hasLength(3));
        expect(rig.overlay.panels[1], isNull);
        expect(rig.overlay.panels.last!.monitor, 0);
      });
    });

    test('moves the drawing overlay with the shared screen, keeping '
        'consent', () {
      fakeAsync((async) {
        final rig = _rig(allow: true, sharing: true, source: _screen1);
        _settle(async);
        expect(rig.overlay.shown, [
          [0],
        ]);

        rig.changeDisplays(const [_plugged, _main, _side]);
        _settle(async);

        expect(rig.overlay.shown, [
          [0],
          [1],
        ]);
        expect(rig.active, isTrue);
        expect(rig.sync.sent.where((s) => !s.allowed), isEmpty);
      });
    });

    test('leaves an overlay that follows a shared window where it is', () {
      fakeAsync((async) {
        final rig = _rig(allow: true, sharing: true, source: _editor);
        _settle(async);
        final hides = rig.overlay.hides;

        rig.changeDisplays(const [_plugged, _main, _side]);
        _settle(async);

        expect(rig.overlay.windows, [263428]);
        expect(rig.overlay.hides, hides);
        expect(rig.active, isTrue);
      });
    });

    test('with no overlay window open changes nothing', () {
      fakeAsync((async) {
        final rig = OverlayRig(windows: true, initial: _call());
        _settle(async);

        rig.changeDisplays(const [_plugged, _main, _side]);
        _settle(async);

        expect(rig.overlay.panels, isEmpty);
        expect(rig.overlay.shown, isEmpty);
      });
    });
  });
}
