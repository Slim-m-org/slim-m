// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click on your own call tile opened a blank pill (a menu with no
/// rows), and a double-click on a camera or screen share did nothing.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/call_participant_tiles.dart';
import 'package:slimm_app/src/widgets/screen_share_stage.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _self = VoiceParticipant(
  identity: 'me',
  name: 'Nick',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
  isCameraOn: true,
);

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: Center(child: child)),
  ),
);

Future<void> _click(
  WidgetTester tester,
  Offset at, {
  int buttons = kPrimaryMouseButton,
}) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: buttons,
  );
  await tester.pump(const Duration(milliseconds: 20));
  await gesture.up();
}

Widget _cameraTile({
  required VoidCallback onExpand,
  VoidCallback? onTap,
  List<Widget> Function(BuildContext, VoidCallback)? menu,
}) => CallParticipantTile(
  participant: _self,
  cameraView: const ColoredBox(color: Colors.blue),
  onExpand: onExpand,
  onTap: onTap == null ? null : (_) => onTap(),
  contextMenuItemsBuilder: menu,
);

void main() {
  testWidgets('right-clicking a menu with no rows opens nothing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(_cameraTile(onExpand: () {}, menu: (_, _) => const [])),
    );

    await _click(
      tester,
      tester.getCenter(find.byType(CallParticipantTile)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppMenu), findsNothing);
  });

  testWidgets('a menu with rows still opens', (tester) async {
    await tester.pumpWidget(
      _wrap(
        _cameraTile(
          onExpand: () {},
          menu: (_, close) => [AppMenuItem(label: 'Mute', onTap: close)],
        ),
      ),
    );

    await _click(
      tester,
      tester.getCenter(find.byType(CallParticipantTile)),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Mute'), findsOneWidget);
  });

  testWidgets('double-clicking a camera tile expands it', (tester) async {
    var expanded = 0;
    await tester.pumpWidget(_wrap(_cameraTile(onExpand: () => expanded++)));
    final at = tester.getCenter(find.byType(CallParticipantTile));

    await _click(tester, at);
    await tester.pump(const Duration(milliseconds: 80));
    await _click(tester, at);
    await tester.pumpAndSettle();

    expect(expanded, 1);
  });

  testWidgets('a single tap opens the profile at once and does not expand', (
    tester,
  ) async {
    var expanded = 0;
    var profile = 0;
    await tester.pumpWidget(
      _wrap(_cameraTile(onExpand: () => expanded++, onTap: () => profile++)),
    );

    await _click(tester, tester.getCenter(find.byType(CallParticipantTile)));
    await tester.pump();

    expect(profile, 1, reason: 'no double-tap window delays the tap');
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(expanded, 0);
  });

  testWidgets('two slow clicks are not a double-click', (tester) async {
    var expanded = 0;
    await tester.pumpWidget(_wrap(_cameraTile(onExpand: () => expanded++)));
    final at = tester.getCenter(find.byType(CallParticipantTile));

    await _click(tester, at);
    await tester.pump(const Duration(milliseconds: 600));
    await _click(tester, at);
    await tester.pumpAndSettle();

    expect(expanded, 0);
  });

  testWidgets('a double-click still lands when the first click raised a '
      'modal barrier over the tile', (tester) async {
    var expanded = 0;
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => _cameraTile(
            onExpand: () => expanded++,
            onTap: () => showGeneralDialog<void>(
              context: context,
              barrierDismissible: true,
              barrierLabel: 'Dismiss',
              pageBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(CallParticipantTile));

    await _click(tester, at);
    await tester.pump(const Duration(milliseconds: 80));
    await _click(tester, at);
    await tester.pumpAndSettle();

    expect(expanded, 1);
  });

  testWidgets('double-clicking a screen share expands it', (tester) async {
    var expanded = 0;
    await tester.pumpWidget(
      _wrap(
        SizedBox(
          width: 600,
          height: 340,
          child: ScreenShareStage(
            sharerName: 'Priya',
            onExpand: () => expanded++,
            child: const ColoredBox(color: Colors.green),
          ),
        ),
      ),
    );
    final at = tester.getCenter(find.byType(ScreenShareStage));

    await _click(tester, at);
    await tester.pump(const Duration(milliseconds: 80));
    await _click(tester, at);
    await tester.pumpAndSettle();

    expect(expanded, 1);
  });
}
