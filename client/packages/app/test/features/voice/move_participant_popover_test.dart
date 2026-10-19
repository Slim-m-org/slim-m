// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Move to..." destination list.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/widgets/move_participant_popover.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_design_system/design_system.dart';

api.Channel _voice(String id, String name) => api.Channel(
  id: id,
  name: name,
  kind: 'voice',
  createdAt: 0,
  permissions: Perm.moveMembers,
);

void main() {
  testWidgets('each destination is its own tappable semantics node', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          myVisibleChannelsProvider.overrideWith(
            (ref) async => [_voice('a', 'lounge'), _voice('b', 'annex')],
          ),
          voiceRosterProvider('b').overrideWith(
            (ref) => Stream.value(const <api.VoiceRosterParticipant>[]),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: MoveDestinations(
              userId: 'u',
              name: 'Bob',
              fromChannelId: 'a',
              onDone: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('annex'), findsOneWidget);
    expect(find.bySemanticsLabel('lounge'), findsNothing);
    handle.dispose();
  });
}
