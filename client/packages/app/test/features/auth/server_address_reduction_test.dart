// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reducing a typed server address to what is safe to persist and reuse.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/server_address_reduction.dart';

void main() {
  group('reduceServerAddress', () {
    test('keeps only the scheme, host and port', () {
      final reduced = reduceServerAddress(Uri.parse('https://chat.example'));
      expect(reduced, Uri.parse('https://chat.example'));
    });

    test('strips userinfo, which dart:io turns into a Basic auth header', () {
      final reduced = reduceServerAddress(
        Uri.parse('https://user:pass@chat.example'),
      );
      expect(reduced.userInfo, isEmpty);
      expect(reduced, Uri.parse('https://chat.example'));
    });

    test('drops a path rather than silently rewriting it to the root', () {
      // See the function's doc comment for why this is deliberate, not lazy.
      final reduced = reduceServerAddress(
        Uri.parse('https://chat.example/sub/path'),
      );
      expect(reduced.path, isEmpty);
    });

    test('drops a query string', () {
      final reduced = reduceServerAddress(
        Uri.parse('https://chat.example?tracking=1'),
      );
      expect(reduced.hasQuery, isFalse);
    });

    test('keeps an explicit port', () {
      final reduced = reduceServerAddress(Uri.parse('http://10.0.0.1:8095'));
      expect(reduced.port, 8095);
    });
  });
}
