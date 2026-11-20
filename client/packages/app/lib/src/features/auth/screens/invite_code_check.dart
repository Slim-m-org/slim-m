// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the invite dialog and the create-account form say about a code they
/// checked with `/invites/{code}/check`, in one wording.
///
/// The server answers every unusable code the same way, expired, spent,
/// revoked or never issued, so codes cannot be mined; naming a reason here
/// would undo that from the client side.
library;

import 'package:slimm_api/api.dart';

import '../../../api_failure.dart';
import '../../../invite_link.dart';

const inviteUnusable =
    'That code is not usable. It may have expired or already been used.';

const inviteLooksLikeWebAddress =
    'That looks like a web address. Paste an invite link that was sent to '
    'you, or just the code.';

/// A reply that is not an invite check, from a host that is not a slim-m Space.
const inviteNotFromASpace = 'The server answered, but not as a slim-m Space.';

/// Why a check that never got an answer failed.
String inviteCheckFailure(ApiException e) => e is TransportException
    ? 'Could not reach that server.'
    : 'The server refused that. ${sentenceCase(e.message)}';

/// What is wrong with [code] before any server is asked, or null.
String? localInviteCodeProblem(String code) {
  if (code.trim().isEmpty) return 'Enter the invite code you were sent.';
  if (looksLikeWebAddress(code)) return inviteLooksLikeWebAddress;
  return null;
}

/// Checks [code] on [client]'s server: null when it can be used, otherwise
/// what to say under the code. Closes [client].
Future<String?> inviteCodeProblem(SlimmApi client, String code) async {
  try {
    if (localInviteCodeProblem(code) case final problem?) return problem;
    final check = await client.checkInvite(code);
    return check is InviteUsable ? null : inviteUnusable;
  } on ApiException catch (error, stack) {
    reportFailure(LogTag.auth, 'check the invite code', error, stack);
    return inviteCheckFailure(error);
  } catch (error, stack) {
    // A host that is not a slim-m Space can shape any reply; see probeServerVersion.
    reportFailure(LogTag.auth, 'check the invite code', error, stack);
    return inviteNotFromASpace;
  } finally {
    client.close();
  }
}
