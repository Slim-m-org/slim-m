// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An invite that arrived from outside the join flow, waiting to be redeemed.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'invite_link.dart';

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
