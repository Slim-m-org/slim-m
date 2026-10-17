// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click on an in-call participant tile used to just reach the same
/// callback a tap does (opening the profile) with no menu at all. It now
/// opens a quick-actions menu instead - `participant_call_menu.dart`'s own
/// rows - through [ContextMenuRegion], the same mechanism every other
/// right-click/long-press menu in this app uses, so a tap still opens the
/// profile directly while a right-click or long-press offers the fuller set.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _participant = VoiceParticipant(
  identity: 'user-priya',
  name: 'Priya',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

/// A right-click the way a mouse makes one: pressed, held, released - not
/// `tapAt`, which releases instantly and never exercises the up-event path
/// `ContextMenuRegion.onSecondaryTapUp` actually depends on.
Future<void> _rightClick(WidgetTester tester, Offset at) async {
  final gesture = await tester.startGesture(
    at,
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await tester.pump(kPressTimeout + const Duration(milliseconds: 20));
  await gesture.up();
  await tester.pumpAndSettle();
}

Widget _wrap(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('a tap still opens the profile directly', (tester) async {
    var opened = 0;
    await tester.pumpWidget(
      _wrap(
        CallParticipantTile(participant: _participant, onTap: (_) => opened++),
      ),
    );

    await tester.tap(find.byType(CallParticipantTile));
    await tester.pump();

    expect(opened, 1);
  });

  testWidgets(
    'a right-click opens the quick-actions menu rather than the profile',
    (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        _wrap(
          CallParticipantTile(
            participant: _participant,
            onTap: (_) => opened++,
            contextMenuItemsBuilder: (context, close) => [
              AppMenuItem(label: 'Mute for me', onTap: close),
            ],
          ),
        ),
      );

      await _rightClick(
        tester,
        tester.getCenter(find.byType(CallParticipantTile)),
      );

      expect(find.text('Mute for me'), findsOneWidget);
      expect(
        opened,
        0,
        reason:
            'a right-click is not a tap - it must not also open the profile',
      );
    },
  );

  testWidgets(
    'a long press opens the same quick-actions menu, the touch equivalent '
    'desktop-vs-mobile law 3 requires',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          CallParticipantTile(
            participant: _participant,
            contextMenuItemsBuilder: (context, close) => [
              AppMenuItem(label: 'Mute for me', onTap: close),
            ],
          ),
        ),
      );

      await tester.longPress(find.byType(CallParticipantTile));
      await tester.pumpAndSettle();

      expect(find.text('Mute for me'), findsOneWidget);
    },
  );

  testWidgets('a null builder leaves the tile inert to a right-click too', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(const CallParticipantTile(participant: _participant)),
    );

    // Not throwing is the assertion: no builder must not mean a crash.
    await _rightClick(
      tester,
      tester.getCenter(find.byType(CallParticipantTile)),
    );

    expect(tester.takeException(), isNull);
  });
}
