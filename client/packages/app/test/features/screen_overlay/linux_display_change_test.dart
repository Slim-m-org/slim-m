// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Linux a change to the monitor layout puts the call panel and the drawing
/// overlay back on the screens they belong to, as `windows_display_change_test`
/// pins for Windows; the runner's `display_watch.cc` sends the notice.
/// Layouts are KWin's and X11's, which keep the top-left monitor at 0,0.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

OverlayMonitor _main({int x = 0, int width = 1920, int height = 1080}) =>
    OverlayMonitor(
      x: x,
      y: 0,
      width: width,
      height: height,
      primary: true,
      name: 'DP-1',
    );

OverlayMonitor _side({int x = 1920}) => OverlayMonitor(
  x: x,
  y: 0,
  width: 1280,
  height: 800,
  primary: false,
  name: 'HDMI-A-1',
);

/// Plugged in on the left: KWin puts it at 0,0 and pushes the rest right, and GDK lists it first.
const _plugged = OverlayMonitor(
  x: 0,
  y: 0,
  width: 1920,
  height: 1080,
  primary: false,
  name: 'DP-2',
);

final _before = [_main(), _side()];
final _pluggedLeft = [_plugged, _main(x: 1920), _side(x: 3840)];

/// The main monitor at 125%: 1536 logical pixels wide, so the side one now starts there.
final _mainRescaled = [_main(width: 1536, height: 864), _side(x: 1536)];

const PortalMonitor _sharedMain = (x: 0, y: 0, width: 1920, height: 1080);
const PortalMonitor _sharedSide = (x: 1920, y: 0, width: 1280, height: 800);

final _inCall = VoiceState(
  channelId: 'call',
  state: VoiceSessionState.connected,
  participants: [rigMe(), rigViewer()],
);

void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

void main() {
  group('a monitor layout change on Linux', () {
    test('reopens the panel on the screen the app is on, at its new index', () {
      fakeAsync((async) {
        final rig = OverlayRig(
          callOverlay: true,
          initial: _inCall,
          monitors: _before,
        );
        _settle(async);
        expect(rig.overlay.shown, [
          [0],
        ]);
        final hides = rig.overlay.hides;

        rig.overlay.appMonitorIndex = 1;
        rig.changeDisplays(_pluggedLeft);
        _settle(async);

        expect(rig.overlay.hides, hides + 1);
        expect(rig.overlay.shown, [
          [0],
          [1],
        ]);
      });
    });

    test('a monitor plugged in at 0,0 does not take the drawing overlay off '
        'the shared screen, now pushed right', () {
      fakeAsync((async) {
        final rig = OverlayRig(portal: _sharedMain, monitors: _before);
        _settle(async);
        expect(rig.overlay.shown, [
          [0],
        ]);

        rig.changeDisplays(_pluggedLeft);
        _settle(async);

        expect(rig.overlay.shown.last, [1]);
        expect(rig.active, isTrue);
        expect(rig.sync.sent.where((s) => !s.allowed), isEmpty);
      });
    });

    test('rescaling the left neighbour keeps the drawing overlay on the '
        'shared screen it moved', () {
      fakeAsync((async) {
        final rig = OverlayRig(portal: _sharedSide, monitors: _before);
        _settle(async);
        expect(rig.overlay.shown, [
          [1],
        ]);

        rig.changeDisplays(_mainRescaled);
        _settle(async);

        expect(rig.overlay.shown.last, [1]);
      });
    });

    test('a change while drawing was off still finds the shared screen once '
        'it is turned on', () {
      fakeAsync((async) {
        final rig = OverlayRig(
          allow: false,
          portal: _sharedMain,
          monitors: _before,
        );
        _settle(async);
        expect(rig.overlay.shown, isEmpty);

        rig.changeDisplays(_pluggedLeft);
        _settle(async);
        rig.container
            .read(voiceSettingsControllerProvider.notifier)
            .setScreenShareAllowAnnotations(true);
        _settle(async);

        expect(rig.overlay.shown, [
          [1],
        ]);
      });
    });

    test('a new share trusts its own portal position again', () {
      fakeAsync((async) {
        final rig = OverlayRig(portal: _sharedMain, monitors: _before);
        _settle(async);
        rig.changeDisplays(_pluggedLeft);
        _settle(async);

        rig.voice.set(_inCall);
        _settle(async);
        rig.voice.set(rigSharing);
        _settle(async);

        expect(rig.overlay.shown.last, [
          0,
        ], reason: 'the new share picked the monitor now at 0,0');
      });
    });

    test('with no overlay window open changes nothing', () {
      fakeAsync((async) {
        final rig = OverlayRig(initial: _inCall);
        _settle(async);

        rig.changeDisplays(_pluggedLeft);
        _settle(async);

        expect(rig.overlay.shown, isEmpty);
        expect(rig.overlay.hides, 0);
      });
    });
  });
}
