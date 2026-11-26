// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call dock keeps the primary controls and one More button, whatever the call offers.
///
/// Soundboard, the canvas toggle and the transcript entry live in More; a pinned item
/// returns to the dock, and captions being on keeps the transcript entry there too.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/live_call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _voice = VoiceFlags(state: VoiceSessionState.connected, channelId: 'c1');

final _everything = [
  myChannelPermissionsProvider('c1').overrideWithValue(
    Perm.connect |
        Perm.speak |
        Perm.useSoundboard |
        Perm.viewChannel |
        Perm.viewTranscripts,
  ),
  liveCallTranscriptIdProvider('c1').overrideWithValue('t1'),
];

Finder _button(String tooltipStart) => find.byWidgetPredicate(
  (w) => w is CallDockButton && w.tooltip.startsWith(tooltipStart),
);

/// The pane a phone window leaves the dock, after the call screen's own margin.
double _paneWidth(double window) => window < 600 ? window - 24 : window;

Future<ProviderContainer> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = await pumpVoiceCallDock(
    tester,
    _voice,
    canvasChannelId: 'c1',
    width: _paneWidth(width),
    touch: width < 600,
    extraOverrides: _everything,
  );
  await tester.pump();
  return container;
}

List<Rect> _dockButtons(WidgetTester tester) => [
  for (final e in find.bySubtype<CallDockButton>().evaluate())
    tester.getRect(find.byElementPredicate((x) => x == e)),
];

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(_button('More'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final width in [1280.0, 1024.0, 800.0, 390.0, 360.0]) {
    testWidgets('one row at $width: primary controls and More, nothing '
        'clipped', (tester) async {
      await _pump(tester, width);
      expect(tester.takeException(), isNull);
      for (final gone in [
        'Soundboard',
        'Show captions',
        'Mark this moment',
        'Open canvas',
        'Transcript',
      ]) {
        expect(_button(gone), findsNothing, reason: '$gone is in More');
      }
      final more = tester.getRect(_button('More'));
      final share = tester.getRect(_button('Share a screen'));
      final leave = tester.getRect(_button('Leave call'));
      expect(more.left, greaterThanOrEqualTo(share.right));
      expect(leave.left, greaterThanOrEqualTo(more.right));
      final left = (width - _paneWidth(width)) / 2;
      for (final r in _dockButtons(tester)) {
        expect(r.center.dy, closeTo(more.center.dy, 0.5), reason: 'one row');
        expect(r.left, greaterThanOrEqualTo(left));
        expect(r.right, lessThanOrEqualTo(left + _paneWidth(width)));
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('More at $width lists soundboard, canvas and transcript '
        'inside the window', (tester) async {
      await _pump(tester, width);
      await _openMore(tester);
      expect(tester.takeException(), isNull);
      for (final row in ['Soundboard', 'Open canvas', 'Transcript']) {
        final rect = tester.getRect(find.text(row).first);
        expect(rect.left, greaterThanOrEqualTo(0), reason: row);
        expect(rect.right, lessThanOrEqualTo(width), reason: row);
        expect(rect.bottom, lessThanOrEqualTo(900), reason: row);
        expect(rect.top, greaterThanOrEqualTo(0), reason: row);
      }
      if (width < 600) {
        final sheetRow = tester.getRect(find.text('Soundboard').first);
        expect(sheetRow.center.dy, greaterThan(450), reason: 'a bottom sheet');
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  }

  testWidgets('captions on keeps the Transcript button in the dock beside '
      'share', (tester) async {
    final container = await _pump(tester, 1280);
    await container
        .read(voiceSettingsControllerProvider.notifier)
        .setShowCaptions(true);
    await tester.pump();
    final transcript = tester.getRect(_button('Transcript'));
    final share = tester.getRect(_button('Share a screen'));
    final more = tester.getRect(_button('More'));
    expect(transcript.left, greaterThanOrEqualTo(share.right));
    expect(transcript.right, lessThanOrEqualTo(more.left));
    expect(transcript.center.dy, closeTo(share.center.dy, 0.5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the Transcript menu holds the captions switch and Mark', (
    tester,
  ) async {
    final container = await _pump(tester, 1280);
    await container
        .read(voiceSettingsControllerProvider.notifier)
        .setShowCaptions(true);
    await tester.pump();
    await tester.tap(_button('Transcript'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final captions = tester.getRect(find.text('Captions'));
    final mark = tester.getRect(find.text('Mark this moment'));
    expect(captions.top, lessThan(mark.top), reason: 'captions lead the menu');
    expect(captions.right, lessThanOrEqualTo(1280));
    expect(mark.right, lessThanOrEqualTo(1280));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a pinned item returns to the dock and is remembered on this '
      'device', (tester) async {
    await _pump(tester, 1280);
    await _openMore(tester);
    await tester.tap(find.text('Show in dock'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Soundboard').last);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 400));
    final pinned = tester.getRect(_button('Soundboard'));
    final share = tester.getRect(_button('Share a screen'));
    final more = tester.getRect(_button('More'));
    expect(pinned.left, greaterThanOrEqualTo(share.right));
    expect(pinned.right, lessThanOrEqualTo(more.left));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('slimm.voice.dock_pinned'), ['soundboard']);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));

    await _pump(tester, 1280);
    expect(_button('Soundboard'), findsOneWidget, reason: 'restored');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a pinned item never joins the tight row below 331dp', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.dock_pinned': ['soundboard'],
    });
    await _pump(tester, 320);
    expect(tester.takeException(), isNull);
    expect(_button('Soundboard'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a pinned item stays in More at phone width, so the row never '
      'clips', (tester) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.dock_pinned': ['soundboard', 'canvas'],
    });
    await _pump(tester, 390);
    expect(tester.takeException(), isNull);
    expect(_button('Soundboard'), findsNothing);
    for (final r in _dockButtons(tester)) {
      expect(r.right, lessThanOrEqualTo(390 - 12));
    }
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 10));
  });
}
