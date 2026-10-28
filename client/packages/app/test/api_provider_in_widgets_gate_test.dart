// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A widget does not call the REST client: it goes through its feature's
/// action provider, so write handling lives with the data layer. The known
/// call sites are listed in `api_provider_in_widgets_allow.txt` and may only
/// shrink.
library;

import 'package:flutter_test/flutter_test.dart';

import 'ratchet_support.dart';

const _allowlist = 'test/api_provider_in_widgets_allow.txt';

void main() {
  test('no new widget reads apiProvider, and fixed ones leave the list', () {
    final found = countByFile(
      'lib/src',
      RegExp(r'\bapiProvider\b'),
      include: (path) =>
          path.startsWith('widgets/') || path.contains('/widgets/'),
    );
    expectRatchet(
      found,
      readAllowlist(_allowlist),
      what: 'a widget reads apiProvider',
      allowlist: _allowlist,
    );
  });
}
