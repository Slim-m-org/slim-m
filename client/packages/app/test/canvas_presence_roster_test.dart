// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Who is here, drawn as a face-pile: cursor-only presence, excluding
/// anyone already on this channel's call (they have their own canvas tile
/// already - see `canvas_presence_roster.dart`'s own doc for why), and
/// nothing shown at all when nobody but this device can be proven present.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/avatar_bytes.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_roster.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _me = VoiceParticipant(
  identity: 'me',
  name: 'Me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

VoiceParticipant _remote(String id, String name) => VoiceParticipant(
  identity: id,
  name: name,
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

// UserAvatar reads userProfileProvider and avatarBytesProvider; both fixed to null so this test needs no real api/session chain.
Widget _wrap(Widget child) => ProviderScope(
  overrides: [
    userProfileProvider.overrideWith((ref, id) async => null),
    avatarBytesProvider.overrideWith((ref, key) async => null),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: child),
  ),
);

void main() {
  // pumpAndSettle rather than a bare pump, so a live cursor update fully lands before each assertion.
  testWidgets('nobody present renders nothing at all', (tester) async {
    await tester.pumpWidget(
      _wrap(const CanvasPresenceRoster(callParticipants: [])),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppAvatar), findsNothing);
  });

  testWidgets("this device's own call participation never counts as "
      'presence', (tester) async {
    await tester.pumpWidget(
      _wrap(const CanvasPresenceRoster(callParticipants: [_me])),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppAvatar), findsNothing);
  });

  testWidgets(
    'a remote call participant renders no avatar - they already have their '
    'own canvas tile',
    (tester) async {
      await tester.pumpWidget(
        _wrap(CanvasPresenceRoster(callParticipants: [_remote('u1', 'Ada')])),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppAvatar), findsNothing);
    },
  );

  testWidgets('a live cursor with no call renders one avatar too', (
    tester,
  ) async {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    cursors.upsert(id: 'u2', x: 0, y: 0, label: 'Priya', colorIndex: 0);

    await tester.pumpWidget(
      _wrap(CanvasPresenceRoster(callParticipants: const [], cursors: cursors)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppAvatar), findsOneWidget);
    expect(find.bySemanticsLabel('On this canvas: Priya'), findsOneWidget);
  });

  testWidgets(
    'the face-pile carries a tooltip explaining it, for a sighted user '
    'hovering rather than reading assistive tech',
    (tester) async {
      final cursors = CanvasCursors();
      addTearDown(cursors.dispose);
      cursors.upsert(id: 'u2', x: 0, y: 0, label: 'Priya', colorIndex: 0);

      await tester.pumpWidget(
        _wrap(
          CanvasPresenceRoster(callParticipants: const [], cursors: cursors),
        ),
      );
      await tester.pumpAndSettle();

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, 'On this canvas: Priya');
      expect(tooltip.excludeFromSemantics, isTrue);
    },
  );

  testWidgets(
    'a live cursor whose id is also on this call is excluded - the call '
    'roster wins, since that id already has a canvas tile',
    (tester) async {
      final cursors = CanvasCursors();
      addTearDown(cursors.dispose);
      cursors.upsert(id: 'u1', x: 0, y: 0, label: 'Ada', colorIndex: 0);

      await tester.pumpWidget(
        _wrap(
          CanvasPresenceRoster(
            callParticipants: [_remote('u1', 'Ada')],
            cursors: cursors,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(AppAvatar), findsNothing);
    },
  );

  testWidgets('past four cursor-only readers, the rest collapse into a +N '
      'chip', (tester) async {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    cursors
      ..upsert(id: 'u1', x: 0, y: 0, label: 'Ada', colorIndex: 0)
      ..upsert(id: 'u2', x: 0, y: 0, label: 'Bob', colorIndex: 1)
      ..upsert(id: 'u3', x: 0, y: 0, label: 'Cy', colorIndex: 2)
      ..upsert(id: 'u4', x: 0, y: 0, label: 'Dee', colorIndex: 3)
      ..upsert(id: 'u5', x: 0, y: 0, label: 'Eve', colorIndex: 0);

    await tester.pumpWidget(
      _wrap(CanvasPresenceRoster(callParticipants: const [], cursors: cursors)),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AppAvatar), findsNWidgets(4));
    expect(find.text('+1'), findsOneWidget);
  });

  testWidgets('a cursor arriving live, with no rebuild from the parent, '
      'still updates the roster', (tester) async {
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);

    await tester.pumpWidget(
      _wrap(CanvasPresenceRoster(callParticipants: const [], cursors: cursors)),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppAvatar), findsNothing);

    cursors.upsert(id: 'u1', x: 0, y: 0, label: 'Ada', colorIndex: 0);
    await tester.pumpAndSettle();

    expect(find.byType(AppAvatar), findsOneWidget);
  });
}
