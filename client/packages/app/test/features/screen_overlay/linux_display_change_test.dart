// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Linux a change to the monitor layout puts the call panel and the drawing
/// overlay back on the screens they belong to, as `windows_display_change_test`
/// pins for Windows; the runner's `display_watch.cc` sends the notice.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

const _main = OverlayMonitor(
  x: 0,
  y: 0,
  width: 1920,
  height: 1080,
  primary: true,
);
const _side = OverlayMonitor(
  x: 1920,
  y: 0,
  width: 1280,
  height: 800,
  primary: false,
);

/// A monitor plugged in to the left, which GDK lists first.
const _plugged = OverlayMonitor(
  x: -1024,
  y: 0,
  width: 1024,
  height: 768,
  primary: false,
);

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
          monitors: const [_main, _side],
        );
        _settle(async);
        expect(rig.overlay.shown, [
          [0],
        ]);
        final hides = rig.overlay.hides;

        rig.overlay.appMonitorIndex = 1;
        rig.changeDisplays(const [_plugged, _main, _side]);
        _settle(async);

        expect(rig.overlay.hides, hides + 1);
        expect(rig.overlay.shown, [
          [0],
          [1],
        ]);
      });
    });

    test('moves the drawing overlay with the shared screen, keeping '
        'consent', () {
      fakeAsync((async) {
        final rig = OverlayRig(
          portal: (x: 0, y: 0, width: 1920, height: 1080),
          monitors: const [_main, _side],
        );
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

    test('with no overlay window open changes nothing', () {
      fakeAsync((async) {
        final rig = OverlayRig(initial: _inCall);
        _settle(async);

        rig.changeDisplays(const [_plugged, _main, _side]);
        _settle(async);

        expect(rig.overlay.shown, isEmpty);
        expect(rig.overlay.hides, 0);
      });
    });
  });
}
