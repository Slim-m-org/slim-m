// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The More menu keeps what it listed when it opened, offers pins only where a
/// pin can take effect, and Switch camera stays one tap away on a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/live_call_transcript.dart';
import 'package:slimm_app/src/features/voice/providers/shortcut_overrides.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/features/voice/widgets/dock_item.dart';
import 'package:slimm_app/src/features/voice/widgets/dock_items.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_platform/platform.dart'
    show AppAction, userShortcutOverrides;
import 'package:slimm_rtc/rtc.dart';

import 'package:slimm_app/src/features/voice/widgets/captions_menu.dart'
    show captionsSwitchKey;

import 'voice_call_controls_harness.dart';

const _voice = VoiceFlags(state: VoiceSessionState.connected, channelId: 'c1');
const _cameraOn = VoiceFlags(
  state: VoiceSessionState.connected,
  channelId: 'c1',
  cameraEnabled: true,
);

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

double _paneWidth(double window) => window < 600 ? window - 24 : window;

Future<ProviderContainer> _pump(
  WidgetTester tester,
  double width, {
  VoiceFlags voice = _voice,
  InertSession? session,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = await pumpVoiceCallDock(
    tester,
    voice,
    canvasChannelId: 'c1',
    width: _paneWidth(width),
    touch: width < 600,
    extraOverrides: _everything,
    session: session,
  );
  await tester.pump();
  return container;
}

Future<void> _settleOut(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 10));
}

Future<void> _openMore(WidgetTester tester) async {
  await tester.tap(_button('More'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

DockItem _item(String id, {bool keepInline = false}) => DockItem(
  id: id,
  name: id,
  inline: const SizedBox(),
  entries: const [],
  keepInline: keepInline,
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'no row can pin into means nothing to pin, Exit fullscreen included',
    () {
      final items = [
        _item('soundboard'),
        _item('exit-fullscreen', keepInline: true),
      ];
      final narrow = splitDockItems(
        items,
        pinned: const [],
        inlineAllowed: false,
      );
      expect(narrow.pinnable, isEmpty);
      expect(narrow.inMore, hasLength(2));
      final wide = splitDockItems(items, pinned: const [], inlineAllowed: true);
      expect(wide.pinnable.map((i) => i.id), ['soundboard']);
    },
  );

  testWidgets('More offers no Show in dock where nothing can be pinned', (
    tester,
  ) async {
    await _pump(tester, 390);
    await _openMore(tester);
    expect(find.text('Soundboard'), findsOneWidget);
    expect(find.text('Show in dock'), findsNothing, reason: 'no pin fits');
    await _settleOut(tester);

    SharedPreferences.setMockInitialValues({});
    await _pump(tester, 1280);
    await _openMore(tester);
    expect(find.text('Show in dock'), findsOneWidget);
    await tester.tap(find.text('Show in dock'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Soundboard').last);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      _button('Soundboard'),
      findsOneWidget,
      reason: 'the pin lands inline',
    );
    await _settleOut(tester);
  });

  testWidgets('captions switched on inside Captions leave the menu open', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'slimm.voice.shortcut_overrides': encodeOverrides({
        AppAction.markCallMoment: const SingleActivator(
          LogicalKeyboardKey.keyK,
          control: true,
        ),
      }),
    });
    addTearDown(() => userShortcutOverrides = const {});
    await _pump(tester, 1280);
    await _openMore(tester);
    await tester.tap(find.text('Captions'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(captionsSwitchKey), findsOneWidget);

    await tester.tap(find.byKey(captionsSwitchKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(_button('Captions'), findsOneWidget, reason: 'now in the dock');
    expect(
      find.byKey(captionsSwitchKey),
      findsOneWidget,
      reason: 'menu stays put',
    );
    expect(find.text('Mark this moment (Ctrl+K)'), findsOneWidget);
    await _settleOut(tester);
  });

  testWidgets('a pin made inside Show in dock leaves its list open', (
    tester,
  ) async {
    await _pump(tester, 1280);
    await _openMore(tester);
    await tester.tap(find.text('Show in dock'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Soundboard').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(_button('Soundboard'), findsOneWidget, reason: 'pinned');
    expect(find.text('Canvas'), findsOneWidget, reason: 'the list is intact');
    await _settleOut(tester);
  });

  testWidgets('Switch camera stays one tap away on a phone while it fits', (
    tester,
  ) async {
    await _pump(
      tester,
      430,
      voice: _cameraOn,
      session: InertSession()
        ..cameraDeviceList = const [
          CameraDevice(id: 'a', label: 'Cam A'),
          CameraDevice(id: 'b', label: 'Cam B'),
        ],
    );
    await tester.pump();
    expect(_button('Switch camera'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _settleOut(tester);
  });
}
