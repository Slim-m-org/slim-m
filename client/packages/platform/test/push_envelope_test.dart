// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Dart sealed-box open against the same server-sealed vectors the iOS
/// extension's tests use, and the envelope rules around it.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const _fixturePath = '../app/ios/RunnerTests/push_envelope_cases.json';

Map<String, dynamic> _fixture() =>
    jsonDecode(File(_fixturePath).readAsStringSync()) as Map<String, dynamic>;

Uint8List _secretKey() => base64Decode(
      _fixture()['recipient_secret_key_base64'] as String,
    );

/// Seals [json] to the fixture's recipient the way the server does.
Uint8List _seal(Map<String, Object?> json, {Uint8List? to}) {
  final key = PrivateKey(to ?? _secretKey());
  return SealedBox(key.publicKey).encrypt(
    Uint8List.fromList(utf8.encode(jsonEncode(json))),
  );
}

Map<String, Object?> _message({Object? sentAt, String? body = 'hello'}) => {
      'domain': 'slim-m.push.v1',
      'version': 1,
      'channel_id': 'c1',
      'message_id': 'm1',
      'sent_at': sentAt,
      'sender': 'ana',
      'channel': 'general',
      'body': body,
    };

Future<KeyStore> _keysHolding(Uint8List secret) async {
  final store = InMemoryKeyStore();
  await store.put(devicePushKeyHandle, base64Encode(secret));
  return store;
}

void main() {
  final now = DateTime.utc(2026, 11, 11, 12);

  group('openSealedBox', () {
    test('opens every envelope the server sealed', () {
      final cases = (_fixture()['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases, isNotEmpty, reason: 'an empty fixture passes vacuously');
      for (final c in cases) {
        final opened = openSealedBox(
          base64Decode(c['sealed_base64'] as String),
          _secretKey(),
        );
        expect(opened, isNotNull, reason: '${c['name']}: did not open');
        expect(utf8.decode(opened!), c['plaintext'], reason: '${c['name']}');
      }
    });

    test('a flipped ciphertext bit does not open', () {
      // The empty case is skipped: pinenacl returns [] for it without a tag check.
      final sealed = base64Decode(
        (_fixture()['cases'] as List)[1]['sealed_base64'] as String,
      );
      for (var i = 0; i < sealed.length; i++) {
        final bad = Uint8List.fromList(sealed)..[i] ^= 1;
        expect(openSealedBox(bad, _secretKey()), isNull, reason: 'byte $i');
      }
    });

    test('the wrong key does not open', () {
      final sealed = _seal(_message());
      expect(openSealedBox(sealed, Uint8List(32)..[0] = 9), isNull);
    });

    test('truncated and empty input answer null', () {
      expect(openSealedBox(Uint8List(0), _secretKey()), isNull);
      expect(openSealedBox(Uint8List(10), _secretKey()), isNull);
    });
  });

  group('openPushPayload', () {
    test('opens a message envelope into its preview', () async {
      final keys = await _keysHolding(_secretKey());
      final payload = base64Encode(_seal(_message(sentAt: 1)));

      final envelope = await openPushPayload(payload, keys);

      expect(envelope!.channelId, 'c1');
      expect(
        envelope.preview(DateTime.fromMillisecondsSinceEpoch(1000)),
        const PushPreviewText(title: 'ana', body: 'hello', channel: 'general'),
      );
    });

    test('no key, no payload and garbage all answer null', () async {
      final payload = base64Encode(_seal(_message()));
      expect(await openPushPayload(payload, InMemoryKeyStore()), isNull);
      final keys = await _keysHolding(_secretKey());
      expect(await openPushPayload(null, keys), isNull);
      expect(await openPushPayload('not base64 !!', keys), isNull);
      expect(await openPushPayload(base64Encode([1, 2, 3]), keys), isNull);
    });

    test('a payload sealed to another key answers null', () async {
      final other = Uint8List(32)..[0] = 7;
      final keys = await _keysHolding(_secretKey());
      final payload = base64Encode(_seal(_message(), to: other));
      expect(await openPushPayload(payload, keys), isNull);
    });

    test('a stored key of the wrong length answers null', () async {
      final keys = await _keysHolding(Uint8List(5));
      final payload = base64Encode(_seal(_message()));
      expect(await openPushPayload(payload, keys), isNull);
    });
  });

  group('PushEnvelope', () {
    PushEnvelope? decode(Map<String, Object?> json) =>
        PushEnvelope.decode(utf8.encode(jsonEncode(json)));

    test('refuses an unknown domain, version or shape', () {
      expect(decode({..._message(), 'domain': 'other'}), isNull);
      expect(decode({..._message(), 'version': 2}), isNull);
      expect(decode({..._message(), 'sender': 5}), isNull);
      expect(PushEnvelope.decode(utf8.encode('[]')), isNull);
      expect(PushEnvelope.decode(utf8.encode('nope')), isNull);
    });

    test('a stale sent_at gives no preview but keeps the routing', () {
      final old = now.subtract(const Duration(minutes: 11));
      final envelope = decode(_message(sentAt: old.millisecondsSinceEpoch))!;
      expect(envelope.preview(now), isNull);
      expect(envelope.channelId, 'c1');
    });

    test('a fresh or absent sent_at is not stale', () {
      final fresh = now.subtract(const Duration(minutes: 9));
      expect(
        decode(_message(sentAt: fresh.millisecondsSinceEpoch))!.preview(now),
        isNotNull,
      );
      expect(decode(_message())!.preview(now), isNotNull);
    });

    test('a content-free or body-less envelope has no preview', () {
      expect(
        decode({
          'domain': 'slim-m.push.v1',
          'version': 1,
          'channel_id': 'c1',
        })!
            .preview(now),
        isNull,
      );
      expect(decode(_message(body: ''))!.preview(now), isNull);
      expect(decode(_message(body: null))!.preview(now), isNull);
    });

    test('a DM carries no channel line', () {
      final dm = {..._message(), 'channel': null};
      expect(decode(dm)!.preview(now)!.channel, isNull);
    });

    test('security envelopes use the server words', () {
      final signIn = decode({
        ..._message(),
        'kind': 'security',
        'event': 'new_device_sign_in',
        'device_name': 'Pixel',
      })!;
      expect(
        signIn.preview(now),
        const PushPreviewText(
          title: 'New sign-in',
          body: 'Pixel signed in to your account.',
        ),
      );
      final alert = decode({
        ..._message(),
        'kind': 'security',
        'event': 'admin_alert',
        'title': 'Heads up',
      })!;
      expect(
        alert.preview(now),
        const PushPreviewText(title: 'Heads up', body: 'hello'),
      );
    });
  });
}
