// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// Self-hosted account recovery: an admin issues a one-time code, and its
/// holder spends it to set a new password. Grouped together because they are
/// the two ends of one flow, even though the schema files them under
/// separate tags (`admin` and `auth`).
extension SlimmApiAdmin on SlimmApi {
  /// Issues a one-time password reset code for [userId]. Requires
  /// ADMINISTRATOR. The plaintext code is returned only this once; the
  /// server stores only its hash. [password] is the caller's own, so a stolen
  /// session cannot mint a way into somebody else's account.
  Future<ResetCodeIssued> issueResetCode(
    String userId, {
    required String password,
  }) async {
    final json = await _send(
      'POST',
      '/admin/users/$userId/reset-code',
      body: {'password': password},
    );
    return ResetCodeIssued.fromJson(json as Map<String, dynamic>);
  }

  /// Clears [userId]'s second factor, for a member who has lost both their
  /// authenticator and their recovery codes. Requires ADMINISTRATOR.
  ///
  /// Deliberately separate from [issueResetCode] rather than something a reset
  /// does on the way past: one answers "I forgot my password" and this answers
  /// "I lost my authenticator". It revokes every live session on the account and
  /// is written to the moderation audit log, so it cannot be done quietly. See
  /// docs/decisions/0048-totp-two-factor.md. [password] is the caller's own.
  Future<void> clearMemberTotp(String userId, {required String password}) =>
      _send(
        'DELETE',
        '/admin/users/$userId/totp',
        body: {'password': password},
        expectNoContent: true,
      );

  /// Spends a reset [code] to set [newPassword]. Unauthenticated, since the
  /// point is recovering an account that cannot currently sign in. Revokes
  /// every live session on the account, since the account may be compromised
  /// rather than just locked out.
  Future<void> resetPassword({
    required String code,
    required String newPassword,
  }) =>
      _send(
        'POST',
        '/auth/reset',
        authenticated: false,
        body: {'code': code, 'new_password': newPassword},
        expectNoContent: true,
      );
}
