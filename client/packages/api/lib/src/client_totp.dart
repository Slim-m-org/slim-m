// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The optional TOTP second factor (decision 0048).
///
/// Enrolment is two calls on purpose. [beginTotpEnrolment] mints a secret and
/// enforces nothing; only [confirmTotpEnrolment] switches the factor on, which
/// is what stops a mis-scanned QR code or an unsynchronised clock from locking
/// somebody out of their own account.
extension SlimmApiTotp on SlimmApi {
  Future<TotpStatus> totpStatus() async {
    final json = await send('GET', '/auth/totp');
    return TotpStatus.fromJson(json as Map<String, dynamic>);
  }

  /// Starts an enrolment. The secret comes back once and is not retrievable
  /// again; calling this a second time replaces an unconfirmed enrolment and is
  /// refused (409) once one is live. [password] is the account password: a
  /// session token alone cannot turn the factor on (decision 0048).
  Future<TotpEnrolment> beginTotpEnrolment({required String password}) async {
    final json = await send(
      'POST',
      '/auth/totp/enrol',
      body: {'password': password},
    );
    return TotpEnrolment.fromJson(json as Map<String, dynamic>);
  }

  /// Switches the factor on against a code from the authenticator, and returns
  /// the recovery codes. They are shown once and stored only as hashes, so a
  /// caller that drops them cannot ask for them again, only reissue. Needs the
  /// account [password] again, for the same reason enrolling does.
  Future<List<String>> confirmTotpEnrolment(
    String code, {
    required String password,
  }) async {
    final json = await send(
      'POST',
      '/auth/totp/confirm',
      body: {'code': code, 'password': password},
    );
    return _recoveryCodes(json);
  }

  /// Replaces the recovery set, against a current code or one of the codes
  /// being replaced. The previous set stops working.
  Future<List<String>> reissueTotpRecoveryCodes(String code) async {
    final json = await send(
      'POST',
      '/auth/totp/recovery-codes',
      body: {'code': code},
    );
    return _recoveryCodes(json);
  }

  /// Turns the factor off, against a current code or an unused recovery code.
  /// Live sessions are deliberately left alone; see decision 0048.
  Future<void> disableTotp(String code) => send(
        'POST',
        '/auth/totp/disable',
        body: {'code': code},
        expectNoContent: true,
      );

  /// Completes a sign-in that [SlimmApiAuth.login] answered with a challenge.
  ///
  /// Unauthenticated, since the caller has no session yet. [code] may be an
  /// authenticator code or a recovery code; the server tries both. The device
  /// fields come from the login request the challenge was minted for, so they
  /// are not resent here, except [installId], which the challenge does not
  /// store.
  Future<TokenPair> verifyTotpChallenge({
    required String challenge,
    required String code,
    String? installId,
  }) async {
    final json = await send(
      'POST',
      '/auth/totp/verify',
      authenticated: false,
      body: {
        'challenge': challenge,
        'code': code,
        if (installId != null) 'install_id': installId,
      },
    );
    final tokens = TokenPair.fromJson(json as Map<String, dynamic>);
    session.set(tokens);
    return tokens;
  }

  List<String> _recoveryCodes(Object? json) =>
      ((json as Map<String, dynamic>)['recovery_codes'] as List<dynamic>)
          .cast<String>();
}
