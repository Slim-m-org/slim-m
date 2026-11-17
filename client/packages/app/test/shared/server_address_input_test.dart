// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_server_probe.dart';
import 'package:slimm_app/src/server_address_input.dart';

void main() {
  test('a bare host assumes https', () {
    expect(
      parseServerAddress(' slim-beta.example.top '),
      Uri.parse('https://slim-beta.example.top'),
    );
  });

  test('a host and port assumes https and keeps the port', () {
    expect(
      parseServerAddress('chat.example:8443'),
      Uri.parse('https://chat.example:8443'),
    );
    expect(
      parseServerAddress('192.168.1.20:8080'),
      Uri.parse('https://192.168.1.20:8080'),
    );
  });

  test('a typed scheme is kept', () {
    expect(
      parseServerAddress('http://chat.example'),
      Uri.parse('http://chat.example'),
    );
    expect(
      parseServerAddress('https://chat.example/app'),
      Uri.parse('https://chat.example/app'),
    );
  });

  test('text naming no host is not an address', () {
    for (final text in ['', '   ', 'https://', 'not an address', '://']) {
      expect(parseServerAddress(text), isNull, reason: text);
    }
  });

  test('the sign-in field probes a bare host over https', () {
    expect(
      probeTarget('chat.example:8443'),
      Uri.parse('https://chat.example:8443'),
    );
  });

  test('a scheme typed without :// is refused, never read as a host', () {
    for (final text in [
      'http:/chat.example',
      'http//chat.example',
      'https:/chat.example',
      'HTTPS//chat.example',
    ]) {
      expect(parseServerAddress(text), isNull, reason: text);
      expect(serverAddressError(text), contains('https://'), reason: text);
    }
  });

  test('other text naming no host gets the plain message', () {
    expect(
      serverAddressError('not an address'),
      'That does not look like a server address.',
    );
  });
}
