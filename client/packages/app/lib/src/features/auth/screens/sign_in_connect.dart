// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in screen's last step: connect to the chosen address, then sign
/// in or register on it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../first_run/providers/first_run_controller.dart'
    show firstRunInviterProvider;
import '../../../providers/providers.dart';
import '../../../push/providers/push_controller.dart';
import '../providers/sign_in_identity.dart';
import '../../../server_address_reduction.dart';
import '../../../whats_new/providers/whats_new_controller.dart';
import '../widgets/server_identity_confirmation.dart';
import 'sign_in_register.dart';

/// Signs in or registers at [address], then starts push. Returns false when
/// the person backed out (the identity check, or a step [signInToAccount]
/// asks about); an [ApiException] from the server is the caller's to explain.
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
Future<bool> connectAndSignIn(
  BuildContext context,
  WidgetRef ref, {
  required Uri address,
  required ({String username, String password}) credentials,
  required bool creatingAccount,
  required String? invite,
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
    return false;
  }
  if (!context.mounted) return false;

  ref.read(chosenServerProvider.notifier).choose(reduced);
  final api = ref.read(apiProvider);
  final identity = await signInIdentity(
    keyStore: ref.read(keyStoreProvider),
    appInfo: ref.read(appInfoProvider.future),
  );
  if (creatingAccount) {
    await registerAccount(
      api,
      identity,
      justRegistered: justRegistered,
      inviter: ref.read(firstRunInviterProvider.notifier),
      credentials: credentials,
      invite: invite,
    );
  } else if (!context.mounted ||
      !await signInToAccount(
        context,
        ref,
        api,
        identity,
        credentials: credentials,
        invite: invite,
      )) {
    return false;
  }
  endFirstContact(firstContact, reduced);
  TextInput.finishAutofillContext();
  pendingInvite.state = null;
  unawaited(push.register());
  return true;
}
