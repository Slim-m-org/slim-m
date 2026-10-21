// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rejoin screen (shown after a failed automatic join, or after hanging
/// up) says who is already in the call.
///
/// A voice channel used to open on a lobby with this same roster above an
/// explicit Join button; the lobby is gone (`voice_screen.dart`'s own doc
/// explains why), but the roster is still worth showing wherever a person
/// is looking at a channel they are not currently connected to.
///
/// The three answers the roster can give have to stay three different
/// things. A deployment with no SFU configured never leaves "not known", so
/// rendering that as an empty room would claim this client checked when it
/// never did - and it gets its own honest sentence rather than nothing at
/// all, which used to read as a stalled load or a missing widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_roster.dart';
import 'package:slimm_app/src/features/voice/screens/voice_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'voice_controller_harness.dart';

const _channel = 'c-lounge';

/// A 501 (no voice configured) fails the automatic join deterministically at
/// the token fetch, landing on the rejoin screen without depending on
/// [FakeSession]'s own join outcome at all.
Future<void> _pump(
  WidgetTester tester,
  AsyncValue<List<api.VoiceRosterParticipant>> roster,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: voiceApi(status: 501),
        );
        ref.onDispose(client.close);
        return client;
      }),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: FakeSession()),
      ),
      voiceRosterProvider(_channel).overrideWith(
        (ref) => switch (roster) {
          AsyncData(:final value) => Stream.value(value),
          AsyncError(:final error) =>
            Stream<List<api.VoiceRosterParticipant>>.error(error),
          _ => const Stream<List<api.VoiceRosterParticipant>>.empty(),
        },
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: VoiceScreen(channelId: _channel)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a roster that has not answered gets its own honest sentence, not '
    'silence and not an empty room',
    (tester) async {
      await _pump(tester, const AsyncLoading());

      expect(find.text('This Space has no voice configured.'), findsOneWidget);
      expect(find.textContaining("Nobody's here"), findsNothing);
      expect(
        find.text("Can't tell who else is here right now."),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'a roster that has been failing rather than merely not yet answering '
    'gets a distinct sentence',
    (tester) async {
      await _pump(
        tester,
        AsyncError<List<api.VoiceRosterParticipant>>(
          Exception('unreachable'),
          StackTrace.empty,
        ),
      );

      expect(find.text('Could not check who is here.'), findsOneWidget);
      expect(
        find.text("Can't tell who else is here right now."),
        findsNothing,
        reason:
            'a poll that has been failing reads differently from one '
            'that simply has not answered yet',
      );
    },
  );

  testWidgets('a checked, empty room says so', (tester) async {
    await _pump(tester, const AsyncData([]));

    expect(find.text("Nobody's here right now"), findsOneWidget);
  });

  testWidgets('the people already in it are named', (tester) async {
    await _pump(
      tester,
      const AsyncData([
        api.VoiceRosterParticipant(userId: 'u1', displayName: 'Ada'),
        api.VoiceRosterParticipant(userId: 'u2', displayName: 'Grace'),
      ]),
    );

    expect(find.textContaining('Ada'), findsWidgets);
    expect(find.textContaining('Grace'), findsWidgets);
    expect(find.text("Nobody's here right now"), findsNothing);
  });

  testWidgets('one person reads as one person, not as a list', (tester) async {
    await _pump(
      tester,
      const AsyncData([
        api.VoiceRosterParticipant(userId: 'u1', displayName: 'Ada'),
      ]),
    );

    expect(find.text('Ada is here'), findsOneWidget);
  });
}
