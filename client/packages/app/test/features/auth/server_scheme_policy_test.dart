// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The https-over-the-internet rule shared by every entry point that commits
/// to a server address, and the LAN exemption it is built on.
///
/// Before this file, only [isLocalAddress] had a test; the rule built on top
/// of it - refuse plain http unless the address is local - had none, even in
/// the one dialog that already enforced it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/server_scheme_policy.dart';

void main() {
  group('isLocalAddress', () {
    test('loopback and private ranges are treated as local', () {
      for (final host in [
        'http://localhost:8080',
        'http://127.0.0.1:8095',
        'http://10.0.0.100:8095',
        'http://192.168.1.20:8080',
        'http://172.16.4.2:8080',
        'http://nas.local:8080',
      ]) {
        expect(isLocalAddress(Uri.parse(host)), isTrue, reason: host);
      }
    });

    test('public addresses are not', () {
      // 172.32 sits just outside the private 172.16/12 block.
      for (final host in [
        'https://chat.example.com',
        'http://8.8.8.8',
        'http://172.32.0.1',
        'http://11.0.0.1',
      ]) {
        expect(isLocalAddress(Uri.parse(host)), isFalse, reason: host);
      }
    });
  });

  group('requireSecureScheme', () {
    test('accepts https anywhere', () {
      expect(
        requireSecureScheme(Uri.parse('https://chat.example.com')),
        isNull,
      );
    });

    test('accepts plain http on a local address in the native apps', () {
      expect(
        requireSecureScheme(Uri.parse('http://10.0.0.100:8095'), onWeb: false),
        isNull,
      );
      expect(
        requireSecureScheme(Uri.parse('http://localhost:8080'), onWeb: false),
        isNull,
      );
    });

    test('refuses plain http on a public address', () {
      final error = requireSecureScheme(Uri.parse('http://chat.example.com'));
      expect(error, isNotNull);
      expect(error, contains('https'));
    });
  });

  group('in a browser', () {
    final httpsPage = Uri.parse('https://slim.example.com/app/');
    final lanPage = Uri.parse('http://192.168.1.20:8080/');

    test('explains a plain http LAN server the page cannot reach', () {
      for (final page in [httpsPage, lanPage]) {
        final error = requireSecureScheme(
          Uri.parse('http://192.168.1.20:8095'),
          onWeb: true,
          page: page,
        );
        expect(error, contains('browser'), reason: '$page');
      }
    });

    test('allows loopback, the page origin and https', () {
      expect(
        requireSecureScheme(
          Uri.parse('http://localhost:8095'),
          onWeb: true,
          page: httpsPage,
        ),
        isNull,
      );
      expect(
        requireSecureScheme(
          Uri.parse('http://192.168.1.20:8080'),
          onWeb: true,
          page: lanPage,
        ),
        isNull,
      );
      expect(
        requireSecureScheme(
          Uri.parse('https://chat.example.com'),
          onWeb: true,
          page: lanPage,
        ),
        isNull,
      );
    });

    test('a native app still accepts a LAN server', () {
      expect(
        requireSecureScheme(
          Uri.parse('http://192.168.1.20:8095'),
          onWeb: false,
          page: httpsPage,
        ),
        isNull,
      );
    });
  });
}
