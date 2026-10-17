// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The failure sentences shared by every place that submits a two-factor code.
library;

import 'package:slimm_api/api.dart' as api;

/// One sentence per failure, shared by every place that submits a code.
///
/// A wrong code is the ordinary case and says what to check; a lockout is told
/// plainly rather than disguised as a wrong code, because a member seeing "that
/// code is wrong" for a correct one concludes their authenticator is broken.
String totpCodeFailure(api.ApiException e) => switch (e) {
  api.BadRequestException() =>
    'That code was not accepted. Codes change every 30 seconds, so check your '
        'phone is showing the current one.',
  api.RateLimitedException() =>
    'Too many incorrect codes. Wait a few minutes and try again.',
  _ => e.message,
};
