// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A Windows call must not listen on TCP when a TCP relay can carry it instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/call_peer_configuration.dart';
import 'package:slimm_rtc/src/start_bitrate_peer_connection.dart';
import 'package:slimm_rtc/src/start_bitrate_room.dart';

Map<String, dynamic> _config(List<Object> urls) => {
      'sdpSemantics': 'unified-plan',
      'iceServers': [
        {'urls': urls, 'username': 'u', 'credential': 'c'},
      ],
    };

void main() {
  group('callPeerConfiguration', () {
    test('drops TCP candidates when TURN over TLS is offered', () {
      final config = _config([
        'turn:turn.example.com:3478?transport=udp',
        'turns:turn.example.com:443?transport=tcp',
      ]);

      final result = callPeerConfiguration(config);

      expect(result['tcpCandidatePolicy'], 'disabled');
      expect(result['iceServers'], config['iceServers']);
      expect(config.containsKey('tcpCandidatePolicy'), isFalse,
          reason: 'LiveKit reuses its map; it must not be changed');
    });

    test('drops TCP candidates when TURN over TCP is offered', () {
      final config = _config(['TURN:turn.example.com:3478?transport=tcp']);

      expect(callPeerConfiguration(config)['tcpCandidatePolicy'], 'disabled');
    });

    test('keeps TCP candidates when only UDP relays are offered', () {
      final config = _config(['turn:turn.example.com:3478?transport=udp']);

      expect(callPeerConfiguration(config), same(config),
          reason: "the SFU's TCP port is then the only way past blocked UDP");
    });

    test('keeps TCP candidates with no relay at all', () {
      final config = <String, dynamic>{'sdpSemantics': 'unified-plan'};

      expect(callPeerConfiguration(config), same(config));
    });

    test('reads a single url string too', () {
      final config = <String, dynamic>{
        'iceServers': [
          {'url': 'turns:turn.example.com:443?transport=tcp'},
        ],
      };

      expect(callPeerConfiguration(config)['tcpCandidatePolicy'], 'disabled');
    });
  });

  group('callPeerFactory', () {
    test('Windows calls create peers through callPeerConfiguration', () {
      expect(callPeerFactory(web: false, windows: true),
          same(createCallPeerConnection));
    });

    test('the browser keeps the start bitrate mirror', () {
      expect(callPeerFactory(web: true, windows: false),
          same(createStartBitratePeerConnection));
    });

    test('other native hosts keep LiveKit\'s own factory', () {
      expect(callPeerFactory(web: false, windows: false), isNull);
    });
  });
}
