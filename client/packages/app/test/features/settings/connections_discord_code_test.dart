// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing a Discord link from Settings: the code row, the paste sheet, and
/// what a link that reached the app says in the Connections card.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/discord_link_finish.dart';
import 'package:slimm_app/src/features/settings/widgets/connections_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _linkedJson = {
  'provider': 'discord',
  'username': 'nick_d',
  'display_name': 'Nick',
  'linked_at': 1,
};

const _code = 'ABCDEFGHJKLMNPQRSTUVWXYZ2';

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Harness {
  _Harness(this.container);

  final ProviderContainer container;
  final posted = <String>[];
}

Future<_Harness> _pump(
  WidgetTester tester,
  http.Response Function(http.Request, _Harness) answer,
) async {
  late final _Harness harness;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.method == 'POST') harness.posted.add(request.body);
        return answer(request, harness);
      }),
    ],
  );
  harness = _Harness(container);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: ConnectionsSection()),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return harness;
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 1));
}

Finder _inSheet(Finder matching) => find.descendant(
  of: find.byKey(const ValueKey('discord-link-code-sheet')),
  matching: matching,
);

Future<void> _openSheetAndPaste(WidgetTester tester, String text) async {
  await tester.tap(find.widgetWithText(AppButton, 'Enter code'));
  await pumpFrames(tester);
  await tester.enterText(
    find.byKey(const ValueKey('discord-link-code-field')),
    text,
  );
  await tester.tap(_inSheet(find.widgetWithText(AppButton, 'Link')));
  await pumpFrames(tester);
}

void main() {
  testWidgets('unlinked: the code row is there; linked: it is gone', (
    tester,
  ) async {
    await _pump(tester, (request, _) => _json(200, []));
    expect(find.text('Link code'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Enter code'), findsOneWidget);
    await _unmount(tester);

    await _pump(tester, (request, _) => _json(200, [_linkedJson]));
    expect(find.text('Link code'), findsNothing);
    expect(find.widgetWithText(AppButton, 'Enter code'), findsNothing);
    await _unmount(tester);
  });

  testWidgets('a pasted code links the account and closes the sheet', (
    tester,
  ) async {
    var linked = false;
    final h = await _pump(tester, (request, _) {
      if (request.url.path == '/me/links/discord/complete') {
        linked = true;
        return _json(200, _linkedJson);
      }
      return _json(200, linked ? [_linkedJson] : []);
    });

    await _openSheetAndPaste(tester, 'abcde-fghjk-lmnpq-rstuv-wxyz2');

    expect(jsonDecode(h.posted.single), {'code': _code});
    expect(find.byKey(const ValueKey('discord-link-code-sheet')), findsNothing);
    expect(find.text('Nick (nick_d)'), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets('a code the server refuses is explained in the sheet', (
    tester,
  ) async {
    await _pump(tester, (request, _) {
      if (request.url.path == '/me/links/discord/complete') {
        return _json(404, {'error': 'nope'});
      }
      return _json(200, []);
    });

    await _openSheetAndPaste(tester, _code);

    expect(_inSheet(find.textContaining('did not work')), findsOneWidget);
    await _unmount(tester);
  });

  testWidgets(
    'a link that failed to finish stays on the card until dismissed',
    (tester) async {
      final h = await _pump(tester, (request, _) {
        if (request.url.path == '/me/links/discord/complete') {
          return _json(404, {'error': 'nope'});
        }
        return _json(200, []);
      });

      await h.container
          .read(discordLinkFinisherProvider)
          .completeDelivered(_code);
      await pumpFrames(tester);
      expect(find.textContaining('did not work'), findsOneWidget);

      await tester.tap(find.widgetWithText(AppButton, 'Dismiss'));
      await pumpFrames(tester);
      expect(find.textContaining('did not work'), findsNothing);
      await _unmount(tester);
    },
  );

  testWidgets('while a delivered link finishes, the row says so', (
    tester,
  ) async {
    final h = await _pump(tester, (request, _) => _json(200, []));

    h.container
        .read(discordLinkStatusProvider.notifier)
        .set(const DiscordLinkFinishing());
    await pumpFrames(tester);

    expect(find.text('Finishing...'), findsOneWidget);
    expect(find.text('Not linked'), findsNothing);
    final link = tester.widget<AppButton>(
      find.widgetWithText(AppButton, 'Link'),
    );
    expect(link.disabled, isTrue);
    await _unmount(tester);
  });
}
