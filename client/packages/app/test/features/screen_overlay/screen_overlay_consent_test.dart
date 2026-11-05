// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Viewers may draw on any share, window shares and desktops without an overlay included; the marks then show on the sharer's own preview.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'overlay_rig.dart';

const _window = ScreenShareSource(id: 'w', name: 'Editor', isWindow: true);

ScreenOverlayState _state(OverlayRig rig) =>
    rig.container.read(screenOverlayControllerProvider);

void main() {
  test('a window share allows drawing without opening the overlay', () {
    fakeAsync((async) {
      final rig = OverlayRig(source: _window);
      async.flushMicrotasks();
      expect(_state(rig).consenting, isTrue);
      expect(rig.active, isFalse);
      expect(rig.overlay.shown, isEmpty);
      final consent = rig.sync.sent.single;
      expect((consent.kind, consent.allowed), ('consent', true));
    });
  });

  test('a desktop that cannot host the overlay still allows drawing', () {
    fakeAsync((async) {
      final rig = OverlayRig(supported: false);
      async.flushMicrotasks();
      expect(_state(rig).consenting, isTrue);
      expect(rig.overlay.shown, isEmpty);
      expect(rig.sync.sent.single.allowed, isTrue);
    });
  });

  test('the window share announces the captured shape once it is known', () {
    fakeAsync((async) {
      final rig = OverlayRig(source: _window);
      async.flushMicrotasks();
      expect(rig.sync.sent.single.aspect, isNull);
      localShareCapturedSize.value = (width: 1000, height: 500);
      addTearDown(() => localShareCapturedSize.value = null);
      async.flushMicrotasks();
      expect(_state(rig).aspect, 2.0);
      expect(rig.sync.sent.last.aspect, 2.0);
    });
  });

  test('stopping a window share withdraws consent', () {
    fakeAsync((async) {
      final rig = OverlayRig(source: _window);
      async.flushMicrotasks();
      rig.voice.set(rigSharing.copyWith(screenSharing: false));
      async.flushMicrotasks();
      expect(_state(rig).consenting, isFalse);
      expect(rig.sync.sent.last.allowed, isFalse);
    });
  });

  test('with the setting off nothing is allowed on any share', () {
    fakeAsync((async) {
      final rig = OverlayRig(allow: false, source: _window);
      async.flushMicrotasks();
      expect(_state(rig).consenting, isFalse);
      expect(rig.sync.sent, isEmpty);
    });
  });

  test(
    'turning the setting off withdraws consent from an unsupported desktop',
    () {
      fakeAsync((async) {
        final rig = OverlayRig(supported: false);
        async.flushMicrotasks();
        unawaited(
          rig.container
              .read(voiceSettingsControllerProvider.notifier)
              .setScreenShareAllowAnnotations(false),
        );
        async.flushMicrotasks();
        expect(_state(rig).consenting, isFalse);
        expect(rig.sync.sent.last.allowed, isFalse);
      });
    },
  );

  test(
    'disposing the container mid-consent withdraws it and does not throw',
    () {
      fakeAsync((async) {
        final rig = OverlayRig();
        async.flushMicrotasks();
        expect(_state(rig).consenting, isTrue);
        rig.container.dispose();
        async.flushMicrotasks();
        expect(rig.sync.sent.last.allowed, isFalse);
        expect(rig.overlay.hides, 1);
      });
    },
  );

  testWidgets('the sharer sees a viewer note on their own preview', (
    tester,
  ) async {
    final rig = OverlayRig(source: _window);
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: ScreenShareStage(
                sharerName: 'Me',
                isLocal: true,
                previewMarksOf: 'me',
                child: ColoredBox(color: Color(0xFF20252B)),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('look here'), findsNothing);

    rig.sync.events.add(
      const api.CanvasScreenAnnotation(
        channelId: 'call',
        userId: 'viewer',
        targetUserId: 'me',
        kind: 'note',
        annotationId: 'n1',
        points: [0.4, 0.4],
        text: 'look here',
        color: 'annotation',
        ended: true,
        allowed: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('look here'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    rig.container.dispose();
  });

  testWidgets('with drawing off the preview shows nothing', (tester) async {
    final rig = OverlayRig(allow: false);
    await tester.pump();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const Scaffold(
            body: SizedBox(
              width: 800,
              height: 450,
              child: ScreenShareStage(
                sharerName: 'Me',
                isLocal: true,
                previewMarksOf: 'me',
                child: ColoredBox(color: Color(0xFF20252B)),
              ),
            ),
          ),
        ),
      ),
    );
    rig.sync.events.add(
      const api.CanvasScreenAnnotation(
        channelId: 'call',
        userId: 'viewer',
        targetUserId: 'me',
        kind: 'note',
        annotationId: 'n1',
        points: [0.4, 0.4],
        text: 'look here',
        color: 'annotation',
        ended: true,
        allowed: false,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('look here'), findsNothing);

    await tester.pumpWidget(const SizedBox());
    rig.container.dispose();
  });
}
