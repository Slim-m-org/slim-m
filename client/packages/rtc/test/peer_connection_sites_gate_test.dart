// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every peer connection the client creates goes through a site that decides
/// whether it gathers TCP candidates, because a passive TCP candidate listens on
/// every interface and Windows then asks the user to allow the app, once per
/// install folder. Reads code with comments and strings blanked ([codeOnly]).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_test_support/source_gates.dart';

final _createPeer = RegExp(r'\bcreatePeerConnection\b');

/// The sites that choose a TCP candidate policy, and why each may.
const _sites = {
  'client/packages/rtc/lib/src/mic_preview_loopback.dart':
      'loopbackPeerConfiguration disables TCP',
  'client/packages/rtc/lib/src/call_peer_configuration.dart':
      'callPeerConfiguration disables TCP when a TCP relay is offered',
  'client/packages/rtc/lib/src/start_bitrate_peer_connection.dart':
      'browser only, where the page cannot listen',
};

void main() {
  final root = findRepoRoot();
  final files = [
    for (final package in Directory('${root.path}/client/packages').listSync())
      if (package is Directory && Directory('${package.path}/lib').existsSync())
        ...Directory('${package.path}/lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
  ];

  String relative(File f) => f.path.substring(root.path.length + 1);

  test('the scan reads the client sources', () {
    expect(files.length, greaterThan(500));
  });

  test('the pattern ignores comments, strings and longer names', () {
    for (final ignored in [
      '// rtc.createPeerConnection({})',
      "log('createPeerConnection failed');",
      'createStartBitratePeerConnection(config);',
    ]) {
      expect(_createPeer.hasMatch(codeOnly(ignored)), isFalse, reason: ignored);
    }
    expect(
        _createPeer.hasMatch(codeOnly('rtc.createPeerConnection({})')), isTrue);
  });

  test('peer connections are only created where TCP is decided', () {
    final strays = [
      for (final file in files)
        if (!_sites.containsKey(relative(file)) &&
            _createPeer.hasMatch(codeOnly(file.readAsStringSync())))
          relative(file),
    ];
    expect(strays, isEmpty,
        reason: 'create it with loopbackPeerConfiguration or '
            'createCallPeerConnection, or add a site here that disables TCP');
  });

  test('every listed site still creates peer connections', () {
    for (final path in _sites.keys) {
      final code = codeOnly(File('${root.path}/$path').readAsStringSync());
      expect(_createPeer.hasMatch(code), isTrue, reason: '$path is stale');
    }
  });
}
