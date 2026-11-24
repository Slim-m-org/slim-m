// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in screen's last step: connect to the chosen address, then sign
/// in or register on it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../first_run/providers/first_run_controller.dart'
    show firstRunInviterProvider;
import '../../../providers/providers.dart';
import '../../../push/providers/push_controller.dart';
import '../providers/sign_in_identity.dart';
import '../../../server_address_reduction.dart';
import '../../../whats_new/providers/whats_new_controller.dart';
import '../widgets/server_identity_confirmation.dart';
import 'sign_in_register.dart';

/// How [connectAndSignIn] ended without an error.
enum ConnectResult {
  signedIn,

  /// The person left the identity check, or a step [signInToAccount] asks about.
  backedOut,

  /// The server has no account by that username; nothing else was sent.
  noAccount,
}

/// Signs in or registers at [address], then starts push. An [ApiException]
/// from the server is the caller's to explain.
///
/// With [lookUpUsername] a sign-in first asks whether the username exists and
/// stops at [ConnectResult.noAccount] when it does not, so the form can offer
/// to create it; the one form serves both (decision 0130). [onAccountFound]
/// runs when the server said the account exists, so a refusal after it is
/// about the password alone.
///
/// On registration the invite code goes in with the signup rather than being
/// redeemed after it: a claimed deployment refuses an uninvited registration
/// outright, so there is no account to redeem against until that call
/// succeeds.
///
/// Sync is deliberately not started here. `SyncController` is session-driven
/// (see its class doc) and its own listener already reacts to the
/// `session.set()` that register or login just performed. Starting it again
/// explicitly raced that listener and opened a second socket, which went on
/// to kick the first, healthy one offline.
///
/// Push registration is fire-and-forget: a denied permission or unreachable
/// server must never hold up a sign-in that is already complete.
///
/// The address is reduced and its identity confirmed before anything is
/// persisted or sent: this is "connecting", in the sense
/// [confirmServerIdentity] means it, and binding the check here (rather
/// than to the field being typed) is what makes a returning sign-in - not
/// only the manual onboarding dialog - a place TOFU's comparison runs.
///
/// A first connect pins silently; a key that later changes is the case the
/// check exists for.
Future<ConnectResult> connectAndSignIn(
  BuildContext context,
  WidgetRef ref, {
  required Uri address,
  required ({String username, String password}) credentials,
  required bool creatingAccount,
  required String? invite,
  bool lookUpUsername = false,
  VoidCallback? onAccountFound,
}) async {
  // Read before the awaits: the session redirect can dispose the screen mid-flight.
  final pendingInvite = ref.read(pendingInviteProvider.notifier);
  final justRegistered = ref.read(justRegisteredProvider.notifier);
  final push = ref.read(pushControllerProvider.notifier);
  final firstContact = ref.read(firstContactServersProvider.notifier);
  final reduced = reduceServerAddress(address);
  if (!await confirmServerIdentity(
    context,
    ref,
    reduced,
    requireSlimServer: true,
  )) {
    return ConnectResult.backedOut;
  }
  if (!context.mounted) return ConnectResult.backedOut;

  ref.read(chosenServerProvider.notifier).choose(reduced);
  final api = ref.read(apiProvider);
  final identity = await signInIdentity(
    keyStore: ref.read(keyStoreProvider),
    appInfo: ref.read(appInfoProvider.future),
    server: reduced,
  );
  if (creatingAccount) {
    final inviter = ref.read(firstRunInviterProvider.notifier);
    try {
      await registerAccount(
        api,
        identity,
        justRegistered: justRegistered,
        inviter: inviter,
        credentials: credentials,
        invite: invite,
      );
    } on ConflictException catch (taken) {
      // Not a new account after all, so it gets no first-run welcome.
      justRegistered.state = false;
      inviter.state = null;
      if (!context.mounted ||
          !await signInToTakenUsername(
            context,
            ref,
            api,
            identity,
            taken: taken,
            credentials: credentials,
            invite: invite,
          )) {
        return ConnectResult.backedOut;
      }
    }
  } else if (lookUpUsername &&
      await _hasAccount(api, credentials.username, onAccountFound) == false) {
    return ConnectResult.noAccount;
  } else if (!context.mounted ||
      !await signInToAccount(
        context,
        ref,
        api,
        identity,
        credentials: credentials,
        invite: invite,
      )) {
    return ConnectResult.backedOut;
  }
  endFirstContact(firstContact, reduced);
  TextInput.finishAutofillContext();
  pendingInvite.state = null;
  unawaited(push.register());
  return ConnectResult.signedIn;
}

/// Whether [username] has an account, or null when the server cannot say:
/// too old to know the question, or asked too often. Signing in then goes
/// ahead as it always did.
Future<bool?> _hasAccount(
  SlimmApi api,
  String username,
  VoidCallback? onFound,
) async {
  try {
    final exists = await api.usernameExists(username);
    if (exists) onFound?.call();
    return exists;
  } on NotFoundException {
    return null;
  } on RateLimitedException {
    return null;
  } on ServerException {
    return null;
  }
}
