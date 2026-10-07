// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tapped `slimm://` link, routed to whatever it names.
///
/// The scheme is registered per platform (Android intent filter, iOS and
/// macOS `CFBundleURLTypes`, the Linux desktop entry's `x-scheme-handler`),
/// so the OS hands a tapped link to the app; this file is the receiving
/// half. A link only ever *fills the join flow in* - `parseInviteLink`'s
/// own doc explains why it must never skip the checks typing has to clear,
/// and that holds exactly as much for a tap as for a paste.
///
/// An *invite* that arrives while signed in is deliberately ignored. One
/// deployment is one community in v1, so "join another server" while signed
/// in is a server switch - a product decision (sign out first? multiple
/// accounts?) that a background URL handler has no standing to make. The
/// signed-out case is the one a shared invite actually serves: the friend
/// being invited does not have an account yet.
///
/// A *message* link is the mirror image: it only works while signed in, and
/// only when it names this very deployment. Signed out there is no transcript
/// to land in and no account to read it with, and a link to somewhere else is
/// the same server switch an invite would be. `message_text.dart` already
/// makes exactly this call for a link tapped inside the app; this is the same
/// decision for one arriving from outside it.
///
/// Windows note: receiving these needs the scheme in the registry, which is
/// an installer concern the repo's packaging does not cover yet; pasting
/// the link into the join dialog remains the Windows path.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'invite_link.dart';
import 'message_link.dart';
import 'providers/providers.dart';
import 'routing/router.dart';
import 'routing/routes.dart';
import 'spotify/spotify_callback.dart';
import 'widgets/message_jump.dart';

/// The invite a tapped link carried, waiting for the onboarding screen to
/// consume it (it opens the redeem dialog prefilled and resets this to
/// null). Null whenever no tap is pending.
final tappedInviteProvider = StateProvider<({Uri server, String code})?>(
  (ref) => null,
);

/// The platform's deep-link URIs. `app_links` replays the launching link to
/// a new subscriber, so one stream covers both a cold start from a tap and
/// a tap while running. Overridden in tests; empty on web, where the
/// "link" is the page's own URL and the router already owns it.
final deepLinkUrisProvider = Provider<Stream<Uri>>(
  (ref) => kIsWeb ? const Stream.empty() : AppLinks().uriLinkStream,
);

/// What a delivered URI should do, decided purely so a test can pin it:
/// the parsed invite to prefill, or null to ignore the link entirely.
({Uri server, String code})? inviteFromDeepLink(
  Uri uri, {
  required bool signedIn,
}) {
  if (signedIn) return null;
  return parseInviteLink(uri.toString());
}

/// The message a delivered URI points at, or null to ignore the link.
///
/// [signedInTo] is this client's own deployment, or null when signed out -
/// which is itself an answer, since a message link is only ever followable
/// from inside a session. Kept separate from [inviteFromDeepLink] rather than
/// folded into one decision because the two want opposite things from being
/// signed in, and one function answering both would have to say so twice.
MessageLink? messageFromDeepLink(Uri uri, {required Uri? signedInTo}) {
  if (signedInTo == null) return null;
  final link = parseMessageLink(uri.toString());
  if (link == null) return null;
  return messageLinkIsHere(link, signedInTo) ? link : null;
}

/// Listens for the app's whole lifetime; read once from bootstrap, next to
/// the sync and push controllers.
final deepLinkControllerProvider = Provider<void>((ref) {
  final guard = SpotifyRouteGuard();
  WidgetsBinding.instance.addObserver(guard);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(guard));
  final sub = ref.read(deepLinkUrisProvider).listen((uri) {
    if (isSpotifyCallback(uri)) {
      unawaited(handleSpotifyCallback(ref, uri));
      return;
    }
    final signedIn = ref.read(sessionProvider).isSignedIn;
    final message = messageFromDeepLink(
      uri,
      signedInTo: signedIn ? ref.read(serverUrlProvider) : null,
    );
    if (message != null) {
      // No currentChannelId to skip the route with: a link from outside the app cannot know what is open.
      jumpToMessage(
        ref.read(routerProvider),
        ref.read,
        currentChannelId: null,
        channelId: message.channelId,
        messageId: message.messageId,
      );
      return;
    }
    final invite = inviteFromDeepLink(uri, signedIn: signedIn);
    if (invite == null) return;
    ref.read(tappedInviteProvider.notifier).state = invite;
    // The redirect keeps a signed-out user inside the join flow, so this can only land somewhere the invite is usable.
    ref.read(routerProvider).go(Routes.onboarding);
  }, onError: (Object error) => debugPrint('deep link stream failed: $error'));
  ref.onDispose(sub.cancel);
});
