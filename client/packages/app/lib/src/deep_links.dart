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
/// A *Discord link* hand-back (`discord-link?code=`) is neither: the browser
/// page that finished Discord's approval opens it so the app can complete the
/// link with its own session, and the server links only for the account that
/// started it. See `discord_link_callback.dart`.
///
/// Windows note: the setup installer registers the scheme in the user's
/// registry and the app forwards a link to a running copy. The zip install
/// does not, so pasting an invite into the join dialog, or the Discord code
/// into Settings, remains the way there.
library;

import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

export 'invite_pending.dart';
import 'features/accounts/providers/account_host.dart';
import 'features/accounts/providers/account.dart' show originOf;
import 'features/accounts/providers/account_providers.dart';
import 'callback_route_guard.dart';
import 'discord_link_callback.dart';
import 'features/settings/providers/discord_link_finish.dart';
import 'invite_link.dart';
import 'invite_pending.dart';
import 'message_link.dart';
import 'providers/providers.dart';
import 'routing/router.dart';
import 'routing/routes.dart';
import 'spotify/spotify_callback.dart';
import 'features/messages/widgets/message_jump.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

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

/// Sends a link to the account it names, switching or adding one as needed.
///
/// False when the link is not this function's to place, so the single-account
/// handling below still decides it.
bool _routeAcrossAccounts(AccountHost host, Uri uri) {
  final message = parseMessageLink(uri.toString());
  if (message != null) {
    final target = host.runtimeFor(originOf(message.server));
    if (target == null || !target.signedIn) return false;
    unawaited(host.switchTo(target.account!.origin));
    jumpToMessage(
      target.container.read(routerProvider),
      target.container.read,
      currentChannelId: null,
      channelId: message.channelId,
      messageId: message.messageId,
    );
    return true;
  }
  final invite = parseInviteLink(uri.toString());
  if (invite == null) return false;
  unawaited(_openInvite(host, invite));
  return true;
}

Future<void> _openInvite(
  AccountHost host,
  ({Uri server, String code}) invite,
) async {
  final existing = host.runtimeFor(originOf(invite.server));
  if (existing != null && existing.signedIn) {
    await host.switchTo(existing.account!.origin);
    return;
  }
  if (host.active?.signedIn ?? false) await host.beginAdd();
  final container = host.active?.container;
  if (container == null) return;
  container.read(tappedInviteProvider.notifier).state = invite;
  container.read(routerProvider).go(Routes.onboarding);
}

/// Listens for tapped links for the whole life of the app.
///
/// Not a provider: a provider dies with its container, and the container
/// bootstrap starts it from is retired when the launch-time account is removed.
class DeepLinkListener {
  DeepLinkListener._(this._host, this._home);

  /// Reads the link stream and host once from [container], then outlives it.
  factory DeepLinkListener.start(ProviderContainer container) {
    final listener = DeepLinkListener._(
      container.read(accountHostProvider),
      container,
    );
    WidgetsBinding.instance.addObserver(listener._guard);
    listener._sub = container
        .read(deepLinkUrisProvider)
        .listen(
          listener._deliver,
          onError: (Object error, StackTrace stack) => AppLog.warning(
            LogTag.platform,
            'The invite link listener failed',
            error: error,
            stack: stack,
          ),
        );
    return listener;
  }

  final AccountHost? _host;

  /// The account on screen when there is no host to ask.
  final ProviderContainer _home;
  final _guard = CallbackRouteGuard();
  late final StreamSubscription<Uri> _sub;

  void dispose() {
    WidgetsBinding.instance.removeObserver(_guard);
    unawaited(_sub.cancel());
  }

  void _deliver(Uri uri) {
    final onScreen = _host?.active?.container ?? _home;
    if (isSpotifyCallback(uri)) {
      unawaited(handleSpotifyCallback(onScreen, uri));
      return;
    }
    if (isDiscordLinkDelivery(uri)) {
      unawaited(_finishDiscordLink(onScreen, uri));
      return;
    }
    final host = _host;
    if (host != null && _routeAcrossAccounts(host, uri)) return;
    _followInSession(onScreen, uri);
  }
}

/// Completes a Discord link in the account on screen, with Settings showing the outcome.
Future<void> _finishDiscordLink(ProviderContainer container, Uri uri) async {
  final code = uri.queryParameters[discordLinkCodeQuery];
  if (code == null || !container.read(sessionProvider).isSignedIn) return;
  final router = container.read(routerProvider);
  if (router.state.uri.path != Routes.personalSettings) {
    unawaited(router.push<void>(Routes.personalSettingsPane('profile')));
  }
  await container.read(discordLinkFinisherProvider).completeDelivered(code);
}

/// Follows a link in one account's own session, when it names that session.
void _followInSession(ProviderContainer container, Uri uri) {
  final signedIn = container.read(sessionProvider).isSignedIn;
  final message = messageFromDeepLink(
    uri,
    signedInTo: signedIn ? container.read(serverUrlProvider) : null,
  );
  if (message != null) {
    // No currentChannelId to skip the route with: a link from outside the app cannot know what is open.
    jumpToMessage(
      container.read(routerProvider),
      container.read,
      currentChannelId: null,
      channelId: message.channelId,
      messageId: message.messageId,
    );
    return;
  }
  final invite = inviteFromDeepLink(uri, signedIn: signedIn);
  if (invite == null) return;
  container.read(tappedInviteProvider.notifier).state = invite;
  // The redirect keeps a signed-out user inside the join flow, so this can only land somewhere the invite is usable.
  container.read(routerProvider).go(Routes.onboarding);
}
