// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The exact wording `http/error.rs`'s `ApiError::Internal` and
/// `http/auth.rs`'s `validate_password` send, read from the shared fixture
/// both sides check against (`crates/slimm-server/tests/fixtures/
/// onboarding_error_strings.json`), the same technique
/// `mention_charset_cases.json` already uses for the mention regex - a
/// server-side edit to either string that forgets the fixture fails a Rust
/// test, and a fixture edit that forgets the client fails here, instead of
/// a snapshot quietly drifting from what the server actually sends.
library;

import 'dart:convert';
import 'dart:io';
import 'package:slimm_test_support/source_gates.dart';

/// The internal-error and password-length strings a real 500/400 from the
/// server actually carries.
class OnboardingErrorStrings {
  const OnboardingErrorStrings._(this.internalError, this.passwordLengthError);

  final String internalError;
  final String passwordLengthError;

  static OnboardingErrorStrings load() {
    final repoRoot = findRepoRoot();
    final fixture = File(
      '${repoRoot.path}/crates/slimm-server/tests/fixtures/onboarding_error_strings.json',
    );
    final raw = jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
    return OnboardingErrorStrings._(
      raw['internal_error'] as String,
      raw['password_length_error'] as String,
    );
  }
}
