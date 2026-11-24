// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Discord or Steam hand-back reaches the account whose server it names, and a web invite reaches a signed-in client.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/settings/providers/discord_link_finish.dart';
import 'package:slimm_app/src/features/settings/providers/link_finish.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_app/src/routing/routes.dart';

import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

GoRouter _lightRouter() => GoRouter(
  initialLocation: Routes.channels,
  routes: [
    GoRoute(path: Routes.channels, builder: (_, _) => const SizedBox()),
    GoRoute(path: Routes.personalSettings, builder: (_, _) => const SizedBox()),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  late StreamController<Uri> links;
  final finished = <({String origin, String code})>[];

  setUp(() async {
    finished.clear();
    links = StreamController<Uri>.broadcast();
    h = AccountHarness(
      extraOverrides: [
        deepLinkUrisProvider.overrideWithValue(links.stream),
        routerProvider.overrideWith((ref) => _lightRouter()),
        discordLinkFinisherProvider.overrideWith(
          (ref) => LinkFinisher(
            service: 'Discord',
            completeLink: (code) async => finished.add((
              origin: ref.read(serverUrlProvider).toString(),
              code: code,
            )),
            status: ref.read(discordLinkStatusProvider.notifier),
            onLinked: () {},
          ),
        ),
      ],
    );
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    addTearDown(
      DeepLinkListener.start(h.host.accounts.first.container).dispose,
    );
  });

  tearDown(() async {
    await links.close();
    await h.dispose();
  });

  test(
    'a code naming the other server finishes there, not on screen',
    () async {
      expect(h.host.active!.account!.origin, _a);

      links.add(Uri.parse('slimm://discord-link?code=ABCDE23456&server=$_b'));
      await pumpEventQueueTimes();

      expect(h.host.active!.account!.origin, _b);
      expect(finished.map((f) => f.code), ['ABCDE23456']);
      expect(Uri.parse(finished.single.origin).host, Uri.parse(_b).host);
    },
  );

  test('a code naming a server with no account is dropped', () async {
    links.add(
      Uri.parse(
        'slimm://discord-link?code=ABCDE23456&server=https://third.example',
      ),
    );
    await pumpEventQueueTimes();

    expect(finished, isEmpty);
    expect(h.host.active!.account!.origin, _a);
  });

  test(
    'an older link naming no server finishes on the account on screen',
    () async {
      links.add(Uri.parse('slimm://discord-link?code=ABCDE23456'));
      await pumpEventQueueTimes();

      expect(finished.map((f) => f.code), ['ABCDE23456']);
      expect(Uri.parse(finished.single.origin).host, Uri.parse(_a).host);
    },
  );

  test(
    'a web invite to another server is opened, not dropped, when signed in',
    () async {
      final container = ProviderContainer(
        overrides: [accountHostProvider.overrideWithValue(h.host)],
      );
      addTearDown(container.dispose);
      final probe = Provider.family<String?, Uri>(
        (ref, uri) => claimWebInviteSignedIn(ref, uri, showJoin: (_) {}),
      );

      final next = container.read(
        probe(Uri.parse('/join?server=https%3A%2F%2Fthird.example&code=abc')),
      );
      await pumpEventQueueTimes();

      expect(next, Routes.channels);
      expect(h.host.adding, isTrue);
      expect(h.host.active!.container.read(tappedInviteProvider)?.code, 'abc');
    },
  );
}
