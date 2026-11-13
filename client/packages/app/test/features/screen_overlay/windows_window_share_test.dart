// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Windows a window share opens the overlay over that window (decision 0116).
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_mapping.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

const _editor = ScreenShareSource(id: '263428', name: 'Editor', isWindow: true);

void _settle(FakeAsync async) {
  async.flushMicrotasks();
  async.elapse(const Duration(milliseconds: 1));
  async.flushMicrotasks();
}

void main() {
  group('windowHandleFromSourceId', () {
    test('reads the handle the capturer uses as the id', () {
      expect(windowHandleFromSourceId('263428'), 263428);
      expect(windowHandleFromSourceId(' 42 '), 42);
    });

    test('anything that is not a handle is refused', () {
      expect(windowHandleFromSourceId('w'), isNull);
      expect(windowHandleFromSourceId('0'), isNull);
      expect(windowHandleFromSourceId('-5'), isNull);
      expect(windowHandleFromSourceId(''), isNull);
    });
  });

  test('a window share on Windows is followed by the overlay', () {
    fakeAsync((async) {
      final rig = OverlayRig(windows: true, source: _editor);
      async.flushMicrotasks();
      expect(rig.active, isTrue);
      expect(rig.overlay.windows, [263428]);
    });
  });

  test('a window share elsewhere still never opens it', () {
    fakeAsync((async) {
      final rig = OverlayRig(source: _editor);
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
    });
  });

  test('a source id that is no handle opens nothing', () {
    fakeAsync((async) {
      final rig = OverlayRig(
        windows: true,
        source: const ScreenShareSource(id: 'w', name: 'x', isWindow: true),
      );
      async.flushMicrotasks();
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
    });
  });

  test('the shape viewers map through is the window, and follows a resize', () {
    fakeAsync((async) {
      final rig = OverlayRig(windows: true, source: _editor);
      localShareCapturedSize.value = (width: 1000, height: 500);
      addTearDown(() => localShareCapturedSize.value = null);
      async.flushMicrotasks();
      expect(rig.container.read(screenOverlayControllerProvider).aspect, 2.0);
      localShareCapturedSize.value = (width: 800, height: 800);
      async.flushMicrotasks();
      expect(rig.container.read(screenOverlayControllerProvider).aspect, 1.0);
      expect(rig.sync.sent.last.aspect, 1.0);
    });
  });

  test('switching from a window to a whole screen moves the overlay', () {
    fakeAsync((async) {
      final rig = OverlayRig(windows: true, source: _editor);
      async.flushMicrotasks();
      rig.voice.share.lastShareSource = const ScreenShareSource(
        id: '0',
        name: 'Screen 1',
      );
      rig.voice.set(rigSharing.copyWith(screenSharing: false));
      _settle(async);
      rig.voice.set(rigSharing);
      _settle(async);
      expect(rig.overlay.windows, [263428, null]);
      expect(rig.active, isTrue);
    });
  });
}
