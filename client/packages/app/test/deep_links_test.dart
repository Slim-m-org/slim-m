// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tapped `slimm://` link: what it does, and just as much what it must not
/// do.
///
/// The decision halves (`inviteFromDeepLink`, `messageFromDeepLink`) are
/// pinned pure. The glue half is exercised through the real controller with
/// the platform stream faked, proving a delivered link sets
/// [tappedInviteProvider] or routes to the channel - and that the cases it
/// must refuse set and route nothing, so a background URL handler can never
/// yank a signed-in user out of their session or into somebody else's server.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/invite_link.dart';
import 'package:slimm_app/src/message_link.dart';
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_platform/platform.dart';

/// Records the jump instead of running it. The real controller pages history
/// out of the local store, which would drag a database (and `path_provider`)
/// into a test about routing decisions; what matters here is that the jump was
/// asked for, with the ids the link carried.
class _RecordingJump extends MessageJumpController {
  _RecordingJump(super.ref);

  ({String channelId, String messageId})? asked;

  @override
  Future<void> jumpTo(String channelId, String messageId) async {
    asked = (channelId: channelId, messageId: messageId);
  }
}

void main() {
  final link = Uri.parse(
    buildInviteLink(server: Uri.parse('https://chat.example:8443'), code: 'C1'),
  );

  group('inviteFromDeepLink', () {
    test('a signed-out tap yields the parsed invite', () {
      final invite = inviteFromDeepLink(link, signedIn: false);
      expect(invite?.server, Uri.parse('https://chat.example:8443'));
      expect(invite?.code, 'C1');
    });

    test('a signed-in tap is ignored: joining elsewhere is a server '
        'switch, not a background navigation', () {
      expect(inviteFromDeepLink(link, signedIn: true), isNull);
    });

    test('a URI that is not an invite link is ignored', () {
      expect(
        inviteFromDeepLink(Uri.parse('slimm://other?x=1'), signedIn: false),
        isNull,
      );
      expect(
        inviteFromDeepLink(Uri.parse('https://chat.example'), signedIn: false),
        isNull,
      );
    });
  });

  final messageLink = Uri.parse(
    buildMessageLink(
      server: Uri.parse('https://chat.example:8443'),
      channelId: 'c-1',
      messageId: 'm-1',
    ),
  );

  group('messageFromDeepLink', () {
    final here = Uri.parse('https://chat.example:8443');

    test('a link to this deployment yields what it points at', () {
      final message = messageFromDeepLink(messageLink, signedInTo: here);
      expect(message?.channelId, 'c-1');
      expect(message?.messageId, 'm-1');
    });

    test('signed out there is nowhere to land, so it is ignored', () {
      expect(messageFromDeepLink(messageLink, signedInTo: null), isNull);
    });

    test('a link to another deployment is refused: following it would be a '
        'server switch, which a tapped link does not get to decide', () {
      expect(
        messageFromDeepLink(
          messageLink,
          signedInTo: Uri.parse('https://other.example'),
        ),
        isNull,
      );
    });

    test('an invite link is not a message link', () {
      expect(messageFromDeepLink(link, signedInTo: here), isNull);
    });
  });

  group('deepLinkControllerProvider', () {
    ({
      ProviderContainer container,
      StreamController<Uri> uris,
      _RecordingJump jump,
    })
    harness({required bool signedIn, Uri? signedInTo}) {
      late final _RecordingJump jump;
      final uris = StreamController<Uri>();
      // A minimal real router: go() must land somewhere without a tree.
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(path: '/', builder: (_, _) => const SizedBox()),
          GoRoute(path: '/join', builder: (_, _) => const SizedBox()),
          GoRoute(
            path: '/channels/:channelId',
            builder: (_, _) => const SizedBox(),
          ),
        ],
      );
      addTearDown(router.dispose);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          routerProvider.overrideWithValue(router),
          deepLinkUrisProvider.overrideWithValue(uris.stream),
          if (signedInTo != null)
            serverUrlProvider.overrideWithValue(signedInTo),
          messageJumpProvider.overrideWith((ref) => jump = _RecordingJump(ref)),
          if (signedIn)
            sessionProvider.overrideWithValue(
              api.SessionStore(
                tokens: const api.TokenPair(
                  userId: 'u-1',
                  accessToken: 't',
                  refreshToken: 'r',
                  accessExpiresAt: 0,
                ),
              ),
            ),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(uris.close);
      container.read(deepLinkControllerProvider);
      // Forces the override to build, so `jump` is assigned before any test reads it.
      container.read(messageJumpProvider);
      return (container: container, uris: uris, jump: jump);
    }

    test('a delivered invite link is held for the join flow', () async {
      final h = harness(signedIn: false);
      h.uris.add(link);
      await Future<void>.delayed(Duration.zero);
      final held = h.container.read(tappedInviteProvider);
      expect(held?.code, 'C1');
      expect(held?.server, Uri.parse('https://chat.example:8443'));
      // The information provider, not the delegate: without a widget tree nothing processes the update further, but the intent is recorded here.
      expect(
        h.container
            .read(routerProvider)
            .routeInformationProvider
            .value
            .uri
            .path,
        '/join',
        reason: 'the tap must land the user on the join flow',
      );
    });

    test('while signed in nothing is held', () async {
      final h = harness(signedIn: true);
      h.uris.add(link);
      await Future<void>.delayed(Duration.zero);
      expect(h.container.read(tappedInviteProvider), isNull);
    });

    test('a delivered message link jumps straight to its channel', () async {
      final h = harness(
        signedIn: true,
        signedInTo: Uri.parse('https://chat.example:8443'),
      );
      h.uris.add(messageLink);
      await Future<void>.delayed(Duration.zero);
      expect(
        h.container
            .read(routerProvider)
            .routeInformationProvider
            .value
            .uri
            .path,
        '/channels/c-1',
        reason: 'the whole point of the link is landing in the transcript',
      );
      expect(
        h.jump.asked,
        (channelId: 'c-1', messageId: 'm-1'),
        reason: 'the channel alone is not the link; the message id is the link',
      );
      expect(
        h.container.read(tappedInviteProvider),
        isNull,
        reason: 'a message link must not be mistaken for an invite',
      );
    });

    test('a message link for another server routes nowhere', () async {
      final h = harness(
        signedIn: true,
        signedInTo: Uri.parse('https://other.example'),
      );
      h.uris.add(messageLink);
      await Future<void>.delayed(Duration.zero);
      expect(
        h.container
            .read(routerProvider)
            .routeInformationProvider
            .value
            .uri
            .path,
        '/',
        reason: 'a link to somebody else\'s deployment must move nothing',
      );
      expect(h.jump.asked, isNull);
    });

    test('junk on the stream is ignored', () async {
      final h = harness(signedIn: false);
      h.uris.add(Uri.parse('slimm://join?code=only'));
      await Future<void>.delayed(Duration.zero);
      expect(h.container.read(tappedInviteProvider), isNull);
    });

    test('a link with a bad percent escape is ignored', () async {
      final h = harness(signedIn: false);
      h.uris.add(Uri.parse('slimm://join?server=%ff&code=x'));
      await Future<void>.delayed(Duration.zero);
      expect(h.container.read(tappedInviteProvider), isNull);
    });

    test('an error on the stream does not stop later links', () async {
      final h = harness(signedIn: false);
      h.uris.addError(StateError('platform channel hiccup'));
      h.uris.add(link);
      await Future<void>.delayed(Duration.zero);
      expect(h.container.read(tappedInviteProvider)?.code, 'C1');
    });
  });
}
