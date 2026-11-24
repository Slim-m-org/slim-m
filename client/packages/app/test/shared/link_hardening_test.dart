// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hostile text in a link cannot reach the router, and a bad escape never throws.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/callback_route_guard.dart';
import 'package:slimm_app/src/discord_link_callback.dart';
import 'package:slimm_app/src/features/settings/providers/discord_link_finish.dart';
import 'package:slimm_app/src/features/settings/providers/link_finish.dart';
import 'package:slimm_app/src/message_link.dart';
import 'package:slimm_app/src/routing/routes.dart';

const _channel = '018f0000-0000-7000-8000-0000000000c1';
const _message = '018f0000-0000-7000-8000-0000000000a1';
const _server = 'https%3A%2F%2Fchat.example';

String _link(String channel, [String id = _message]) =>
    'slimm://message?server=$_server&channel=$channel&id=$id';

void main() {
  group('a message link only carries ids', () {
    test('a well formed link parses', () {
      expect(parseMessageLink(_link(_channel)), isNotNull);
    });

    test('route syntax in the channel or the message is refused', () {
      for (final hostile in [
        '$_channel%23',
        '$_channel%3Fx%3D',
        '$_channel%2Fx',
        '..%2Fsettings',
        '%2E%2E%2Fpanel%2Fm%2Fc',
        'c1',
      ]) {
        expect(parseMessageLink(_link(hostile)), isNull, reason: hostile);
        expect(parseMessageLink(_link(_channel, hostile)), isNull);
      }
    });
  });

  group('routes encode what they are given', () {
    test('a fragment or query in an id stays inside its segment', () {
      final uri = Uri.parse(Routes.channel('a#b?c', openChat: true));
      expect(uri.pathSegments, ['channels', 'a#b?c']);
      expect(uri.queryParameters, {'chat': '1'});
      expect(Uri.parse(Routes.message('a/b', 'c#d')).pathSegments, [
        'channels',
        'a/b',
        'm',
        'c#d',
      ]);
    });

    test('a bad percent escape in the flags is not a flag', () {
      expect(Routes.opensChat(Uri.parse('/channels/x?chat=%ff')), isFalse);
      expect(
        Routes.opensDetails(Uri.parse('/channels/x?details=%ff')),
        isFalse,
      );
    });
  });

  group('CallbackRouteGuard', () {
    final guard = CallbackRouteGuard();
    Future<bool> claims(String link) =>
        guard.didPushRouteInformation(RouteInformation(uri: Uri.parse(link)));

    test('keeps message and invite links out of the router', () async {
      expect(await claims(_link(_channel)), isTrue);
      expect(await claims('slimm://message?channel=%ff'), isTrue);
      expect(await claims('slimm://join?server=$_server&code=abc'), isTrue);
    });

    test('leaves ordinary locations alone', () async {
      expect(await claims('https://chat.example/channels/x'), isFalse);
    });
  });

  group('a hand-back link', () {
    test('names its server and ignores an unreadable query', () {
      final named = parseLinkHandBack(
        Uri.parse('slimm://discord-link?code=ABC&server=$_server'),
      );
      expect(named?.server, Uri.parse('https://chat.example'));
      expect(named?.service, LinkService.discord);
      expect(
        parseLinkHandBack(Uri.parse('slimm://steam-link?code=%ff')),
        isNull,
      );
      expect(parseLinkHandBack(Uri.parse('/link/steam?code=%ff')), isNull);
      expect(parseLinkCode('slimm://discord-link?code=%ff'), isNull);
    });

    test(
      'a web visit while signed out is kept and finished after sign-in',
      () async {
        final finished = <String>[];
        final container = ProviderContainer(
          overrides: [
            discordLinkFinisherProvider.overrideWith(
              (ref) => LinkFinisher(
                service: 'Discord',
                completeLink: (code) async => finished.add(code),
                status: ref.read(discordLinkStatusProvider.notifier),
                onLinked: () {},
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final probe = Provider.family<String?, ({Uri uri, bool signedIn})>(
          (ref, args) =>
              claimLinkHandBack(ref, args.uri, signedIn: args.signedIn),
        );
        final visit = Uri.parse('/link/discord?code=ABCDE23456');

        expect(container.read(probe((uri: visit, signedIn: false))), isNull);
        await Future<void>.value();
        expect(finished, isEmpty);

        final next = container.read(
          probe((uri: Uri.parse('/channels'), signedIn: true)),
        );
        await Future<void>.value();
        expect(next, Routes.personalSettingsPane('profile'));
        expect(finished, ['ABCDE23456']);

        container.read(probe((uri: Uri.parse('/channels/x'), signedIn: true)));
        await Future<void>.value();
        expect(finished, hasLength(1), reason: 'a parked code is spent once');
      },
    );
  });
}
