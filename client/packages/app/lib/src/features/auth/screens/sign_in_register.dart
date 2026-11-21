// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two account calls behind the sign-in screen: creating one, and
/// signing in to one that exists.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../../providers/toasts.dart';
import '../../first_run/providers/first_run_inviter.dart';
import '../../settings/widgets/totp_sign_in_prompt.dart';
import '../providers/sign_in_identity.dart';
import 'sign_in_invite_redeem.dart';

typedef NewAccountCredentials = ({String username, String password});

/// Creates the account; the server defaults the display name to the username.
Future<void> registerAccount(
  SlimmApi api,
  SignInIdentity identity, {
  required StateController<bool> justRegistered,
  required StateController<String?> inviter,
  required NewAccountCredentials credentials,
  String? invite,
}) async {
  // Before the call: its session change is what starts the what's-new check.
  justRegistered.state = true;
  await rememberInviter(api, inviter, invite);
  final (:username, :password) = credentials;
  await api.register(
    username: username,
    password: password,
    deviceName: identity.deviceName,
    inviteCode: invite,
    clientKind: identity.clientKind,
    clientVersion: identity.clientVersion,
    installId: identity.installId,
  );
}

/// What the create form does when its username already exists: someone
/// signing back in, if the password is that account's. Fresh installs open on
/// creating an account, and people with one made a second by picking a new
/// name here. Rethrows [taken] when the password is not the account's.
Future<bool> signInToTakenUsername(
  BuildContext context,
  WidgetRef ref,
  SlimmApi api,
  SignInIdentity identity, {
  required ConflictException taken,
  required NewAccountCredentials credentials,
  String? invite,
}) async {
  // Read before the awaits: signing in can dispose the screen mid-flight.
  final toasts = ref.read(toastsProvider.notifier);
  final bool signedIn;
  try {
    signedIn = await signInToAccount(
      context,
      ref,
      api,
      identity,
      credentials: credentials,
      invite: invite,
    );
  } on ApiException {
    throw taken;
  }
  if (signedIn) {
    toasts.show(
      'You already have an account here, so you are signed in to it.',
    );
  }
  return signedIn;
}

/// Signs in to an existing account; false when the second-factor sheet was
/// abandoned or [context] left, so no session exists yet.
Future<bool> signInToAccount(
  BuildContext context,
  WidgetRef ref,
  SlimmApi api,
  SignInIdentity identity, {
  required NewAccountCredentials credentials,
  String? invite,
}) async {
  final (:username, :password) = credentials;
  final outcome = await api.login(
    username: username,
    password: password,
    deviceName: identity.deviceName,
    clientKind: identity.clientKind,
    clientVersion: identity.clientVersion,
    installId: identity.installId,
  );
  if (outcome case SignInChallenged(:final challenge)) {
    if (!context.mounted) return false;
    final signedIn = await promptForTotpCode(
      context,
      ref,
      challenge,
      installId: identity.installId,
    );
    if (!signedIn) return false;
  }
  // An existing account can still spend a code, for the role it grants.
  if (invite != null) await redeemInviteQuietly(api, invite);
  return true;
}
