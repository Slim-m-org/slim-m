// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Android background handler's preview step: a sealed payload becomes
/// the sender and text, and every failure leaves the generic line in place.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:slimm_app/src/push/android_push_messages.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

final _secret = Uint8List.fromList(List.generate(32, (i) => i + 1));
final _now = DateTime.utc(2026, 11, 11, 12);

String _payload(Map<String, Object?> json) => base64Encode(
  SealedBox(
    PrivateKey(_secret).publicKey,
  ).encrypt(Uint8List.fromList(utf8.encode(jsonEncode(json)))),
);

Map<String, Object?> _envelope({int? sentAt, String? channel = 'general'}) => {
  'domain': 'slim-m.push.v1',
  'version': 1,
  'sent_at': sentAt ?? _now.millisecondsSinceEpoch,
  'sender': 'ana',
  'channel': channel,
  'body': 'lunch?',
};

Future<InMemoryKeyStore> _store() async {
  final store = InMemoryKeyStore();
  await store.put(devicePushKeyHandle, base64Encode(_secret));
  return store;
}

void main() {
  test('a sealed message becomes sender, channel and text', () async {
    final data = {'kind': 'message', 'payload': _payload(_envelope())};
    final preview = await openPreview(data, await _store(), now: _now);

    expect(preview!.body, 'lunch?');
    expect(previewTitle(preview), 'ana in #general');
  });

  test('a DM title is the sender alone', () async {
    final data = {'payload': _payload(_envelope(channel: null))};
    final preview = await openPreview(data, await _store(), now: _now);

    expect(previewTitle(preview!), 'ana');
  });

  test('a stale envelope falls back to the generic line', () async {
    final old = _now.subtract(const Duration(minutes: 30));
    final data = {
      'payload': _payload(_envelope(sentAt: old.millisecondsSinceEpoch)),
    };

    expect(await openPreview(data, await _store(), now: _now), isNull);
  });

  test('no key, no payload or a non-string payload fall back', () async {
    final payload = _payload(_envelope());
    expect(
      await openPreview({'payload': payload}, InMemoryKeyStore(), now: _now),
      isNull,
    );
    final keys = await _store();
    expect(await openPreview({'kind': 'message'}, keys, now: _now), isNull);
    expect(await openPreview({'payload': 7}, keys, now: _now), isNull);
    expect(await openPreview({'payload': '%%%'}, keys, now: _now), isNull);
  });

  test('a content-free envelope falls back', () async {
    final data = {
      'payload': _payload({'domain': 'slim-m.push.v1', 'version': 1}),
    };

    expect(await openPreview(data, await _store(), now: _now), isNull);
  });
}
