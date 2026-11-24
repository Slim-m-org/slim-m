// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Quick taps on one reaction reach the server one at a time, in tap order,
/// and the chip ends on what the server holds.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/reaction_toggle_queue.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';

import '../../channel_history_harness.dart' show channelMessage;
import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'u1',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 9999999999999,
);

const _emoji = ':wave:';

class _Reactions {
  _Reactions(this.status);

  int status;
  final List<String> sent = [];
  bool hold = false;
  final List<Completer<void>> waiting = [];

  Future<http.Response> handle(http.Request request) async {
    sent.add(request.method);
    if (hold) {
      final gate = Completer<void>();
      waiting.add(gate);
      await gate.future;
    }
    return http.Response('', status);
  }
}

Future<(ProviderContainer, WidgetRef)> _mount(
  WidgetTester tester,
  _Reactions server,
) async {
  late WidgetRef probe;
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  container.read(messageExtrasProvider.notifier).applyMessages([
    channelMessage(1),
  ]);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            probe = ref;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return (container, probe);
}

Future<void> _tap(WidgetRef ref) =>
    setReaction(ref, 'm1', _emoji, wasActive: hasReacted(ref, 'm1', _emoji));

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  testWidgets('a second tap waits for the first answer, then goes out', (
    tester,
  ) async {
    final server = _Reactions(204)..hold = true;
    final (container, ref) = await _mount(tester, server);

    await tester.runAsync(() async {
      final first = _tap(ref);
      final second = _tap(ref);
      await _settle();
      expect(server.sent, ['PUT'], reason: 'the remove must wait its turn');
      server.waiting.removeAt(0).complete();
      await _settle();
      expect(server.sent, ['PUT', 'DELETE']);
      server.waiting.removeAt(0).complete();
      await Future.wait([first, second]);
    });

    expect(hasReacted(ref, 'm1', _emoji), isFalse);
    expect(container.read(reactionTogglesInFlightProvider), isEmpty);
  });

  testWidgets('taps that end where the server already is send nothing more', (
    tester,
  ) async {
    final server = _Reactions(204)..hold = true;
    final (container, ref) = await _mount(tester, server);

    await tester.runAsync(() async {
      final first = _tap(ref);
      await _tap(ref);
      await _tap(ref);
      await _settle();
      server.waiting.removeAt(0).complete();
      await first;
    });

    expect(server.sent, ['PUT']);
    final chip = container
        .read(messageExtrasProvider.notifier)
        .extrasFor('m1')
        .reactions
        .single;
    expect((chip.reacted, chip.count), (true, 1));
  });

  testWidgets('a refused toggle puts back what the server holds', (
    tester,
  ) async {
    final server = _Reactions(403);
    final (container, ref) = await _mount(tester, server);

    await tester.runAsync(() => _tap(ref));

    expect(server.sent, ['PUT']);
    expect(
      container.read(messageExtrasProvider.notifier).extrasFor('m1').reactions,
      isEmpty,
    );
  });
}
