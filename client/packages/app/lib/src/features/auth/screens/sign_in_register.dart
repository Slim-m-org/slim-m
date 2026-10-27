// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The account-creation call behind the sign-in screen's register mode.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';

import '../../first_run/providers/first_run_inviter.dart';
import '../providers/sign_in_identity.dart';

typedef NewAccountCredentials = ({
  String username,
  String displayName,
  String password,
});

/// Creates the account; an empty display name falls back to the username.
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
  final (:username, :displayName, :password) = credentials;
  await api.register(
    username: username,
    displayName: displayName.isEmpty ? username : displayName,
    password: password,
    deviceName: identity.deviceName,
    inviteCode: invite,
    clientKind: identity.clientKind,
    clientVersion: identity.clientVersion,
    installId: identity.installId,
  );
}
