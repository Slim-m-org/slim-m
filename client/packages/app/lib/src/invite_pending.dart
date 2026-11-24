// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An invite that arrived from outside the join flow, waiting to be redeemed.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/accounts/providers/account.dart' show originOf;
import 'features/accounts/providers/account_host.dart';
import 'features/accounts/providers/account_providers.dart';
import 'invite_link.dart';
import 'routing/routes.dart';

/// The invite a tapped or opened link carried, waiting for the onboarding
/// screen to consume it (it opens the redeem dialog prefilled and resets this
/// to null). Null whenever no link is pending.
final tappedInviteProvider = StateProvider<({Uri server, String code})?>(
  (ref) => null,
);

/// Hands the invite in a web `/join?server=&code=` URL to [tappedInviteProvider]
/// and returns the clean location to continue to, or null when [uri] has none.
///
/// This is where the landing page's "Open in browser" button arrives. The
/// state is written on a microtask because a redirect can run while the
/// router is still being built.
String? claimWebInvite(Ref ref, Uri uri) {
  if (uri.path != '/join' || !uri.hasQuery) return null;
  final invite = parseInviteQuery(uri);
  if (invite == null) return null;
  Future.microtask(
    () => ref.read(tappedInviteProvider.notifier).state = invite,
  );
  return '/join';
}

/// Opens an invite for a signed-in person: the account that already holds that server, or a new one added beside this one.
///
/// [showJoin] sends the account it hands the invite to into the join flow, which consumes it.
Future<void> openInvite(
  AccountHost host,
  ({Uri server, String code}) invite, {
  required void Function(ProviderContainer container) showJoin,
}) async {
  final existing = host.runtimeFor(originOf(invite.server));
  if (existing != null && existing.signedIn) {
    await host.switchTo(existing.account!.origin);
    return;
  }
  if (host.active?.signedIn ?? false) await host.beginAdd();
  final container = host.active?.container;
  if (container == null) return;
  container.read(tappedInviteProvider.notifier).state = invite;
  showJoin(container);
}

/// [claimWebInvite] for a person who is already signed in: hands the invite to [openInvite] and carries on to the channels.
String? claimWebInviteSignedIn(
  Ref ref,
  Uri uri, {
  required void Function(ProviderContainer container) showJoin,
}) {
  if (uri.path != Routes.onboarding || !uri.hasQuery) return null;
  final invite = parseInviteQuery(uri);
  final host = ref.read(accountHostProvider);
  if (invite == null || host == null) return null;
  Future.microtask(() => openInvite(host, invite, showJoin: showJoin));
  return Routes.channels;
}
