// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server decides which addresses this device is asked to dial, so the
/// parser only lets through a private IP literal on the server's own web port,
/// and loopback only for a server that is itself on loopback.
library;

import 'package:slimm_api/src/direct_route.dart';
import 'package:test/test.dart';

List<String> _taken(
  List<String> raw, {
  int port = 443,
  String host = 'slim.example',
}) =>
    [
      for (final a
          in parseDirectAddresses(raw, publicPort: port, publicHost: host))
        '${a.host}:${a.port}',
    ];

void main() {
  test('the ordinary LAN address on the server\'s own port is kept', () {
    expect(_taken(['10.0.0.100:443']), ['10.0.0.100:443']);
    expect(_taken(['192.168.1.5:8443'], port: 8443), ['192.168.1.5:8443']);
    expect(_taken(['172.16.0.1:443', '172.31.255.1:443']),
        ['172.16.0.1:443', '172.31.255.1:443']);
  });

  test('a service port on a loopback or LAN address is ignored', () {
    expect(
        _taken(['127.0.0.1:22', '10.0.0.1:22', '192.168.0.1:6379']), isEmpty);
  });

  test('a public address is ignored even on the right port', () {
    expect(
      _taken([
        '8.8.8.8:443',
        '203.0.113.7:443',
        '172.32.0.1:443',
        '172.15.0.1:443',
        '11.0.0.1:443',
      ]),
      isEmpty,
    );
  });

  test('a hostname is ignored, only IP literals are dialled', () {
    expect(
        _taken(['nas.lan:443', 'localhost:443', 'example.com:443']), isEmpty);
  });

  test('link-local is allowed on the right port', () {
    expect(_taken(['169.254.1.1:443']), ['169.254.1.1:443']);
  });

  test('loopback is this device, so only a loopback server may name it', () {
    expect(_taken(['127.0.0.1:443', '[::1]:443', '[::ffff:127.0.0.1]:443']),
        isEmpty);
    expect(_taken(['127.0.0.1:443', '[::1]:443'], host: '127.0.0.1'),
        ['127.0.0.1:443', '::1:443']);
    expect(_taken(['127.0.0.1:443'], host: 'localhost'), ['127.0.0.1:443']);
  });

  test('a server on a port that is not a web port gets no direct route', () {
    expect(_taken(['10.0.0.1:6379'], port: 6379), isEmpty);
    expect(_taken(['192.168.1.5:9222'], port: 9222), isEmpty);
    expect(_taken(['192.168.1.5:8080'], port: 8080), isEmpty);
  });

  test('IPv6 accepts unique-local and link-local only', () {
    expect(
      _taken(['[fd12::1]:443', '[fe80::1]:443']),
      ['fd12::1:443', 'fe80::1:443'],
    );
    expect(_taken(['[2001:db8::1]:443', '[2606:4700::1]:443']), isEmpty);
  });

  test('an IPv4-mapped IPv6 address follows its IPv4 range', () {
    expect(_taken(['[::ffff:10.0.0.1]:443']), ['::ffff:10.0.0.1:443']);
    expect(_taken(['[::ffff:8.8.8.8]:443']), isEmpty);
  });

  test('malformed entries are dropped', () {
    expect(_taken(['10.0.0.1', '10.0.0.1:abc', ':443', '10.0.0.999:443', '']),
        isEmpty);
  });
}
