// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The idle voice join bar names who is online only when the call has someone
/// in it: telling you people are online in an empty lounge is noise.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/providers/voice_roster.dart';
import 'package:slimm_app/src/screens/voice_idle/voice_join_bar.dart';
import 'package:slimm_design_system/design_system.dart';

const _channel = 'c1';

Future<void> _pump(
  WidgetTester tester, {
  required List<api.VoiceRosterParticipant> here,
}) async {
  const kiki = api.UserProfile(
    id: 'kiki',
    username: 'kiki',
    displayName: 'Kiki',
    createdAt: 0,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceRosterProvider(_channel).overrideWith((ref) => Stream.value(here)),
        channelMembersProvider(
          _channel,
        ).overrideWith((ref) async => const [kiki]),
        presenceSeedProvider(_channel).overrideWith((ref) async {}),
        presenceForProvider('kiki').overrideWithValue(AppPresence.online),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: VoiceJoinBar(
            channelId: _channel,
            compact: false,
            lastCallAt: null,
            now: 0,
            onJoin: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an empty lounge does not say who is online', (tester) async {
    await _pump(tester, here: const []);

    expect(find.text("Nobody's here right now"), findsOneWidget);
    expect(find.textContaining('is online'), findsNothing);
    expect(find.textContaining('are online'), findsNothing);
  });

  testWidgets('a lounge with someone in it still says who else is online', (
    tester,
  ) async {
    await _pump(
      tester,
      here: const [
        api.VoiceRosterParticipant(userId: 'ann', displayName: 'Ann'),
      ],
    );

    expect(find.text('Ann is here'), findsOneWidget);
    expect(find.textContaining('Kiki is online'), findsOneWidget);
  });
}
