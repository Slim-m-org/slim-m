// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Android background handler's preview step: a sealed payload becomes
/// the sender and text, and every failure leaves the generic line in place.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pinenacl/x25519.dart';
import 'package:slimm_app/src/features/accounts/providers/notification_target.dart';
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

Map<String, Object?> _envelope({
  int? sentAt,
  String? channel = 'general',
  String channelId = 'c1',
}) => {
  'domain': 'slim-m.push.v1',
  'version': 1,
  'channel_id': channelId,
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

    expect(preview!.text.body, 'lunch?');
    expect(previewTitle(preview.text), 'ana in #general');
  });

  test('a DM title is the sender alone', () async {
    final data = {'payload': _payload(_envelope(channel: null))};
    final preview = await openPreview(data, await _store(), now: _now);

    expect(previewTitle(preview!.text), 'ana');
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

  test('two conversations stack and one conversation replaces', () async {
    final keys = await _store();
    Future<int> idOf(String channelId) async => (await openPreview(
      {'payload': _payload(_envelope(channelId: channelId))},
      keys,
      now: _now,
    ))!.notificationId;

    expect(await idOf('c1'), await idOf('c1'));
    expect(await idOf('c1'), isNot(await idOf('c2')));
    expect(await idOf('c1'), greaterThanOrEqualTo(previewNotificationIdBase));
  });

  test('a sealed admin alert opens with its own title and body', () async {
    final data = {
      'kind': 'admin_alert',
      'payload': _payload({
        'domain': 'slim-m.push.v1',
        'version': 1,
        'kind': 'security',
        'event': 'admin_alert',
        'sent_at': _now.millisecondsSinceEpoch,
        'title': 'Disk almost full',
        'body': 'Media volume is at 95%',
      }),
    };
    final preview = await openPreview(data, await _store(), now: _now);

    expect(previewTitle(preview!.text), 'Disk almost full');
    expect(preview.text.body, 'Media volume is at 95%');
  });

  group('incomingCallFor', () {
    Map<String, Object?> ring({String? name}) => {
      'domain': 'slim-m.push.v1',
      'version': 1,
      'kind': 'call',
      'channel_id': 'dm1',
      'ring_id': 'ring-7',
      'caller_id': 'u1',
      'sent_at': _now.millisecondsSinceEpoch,
      'caller_name': ?name,
    };

    test('names the caller and uses the ring id from the envelope', () async {
      final data = {'kind': 'call', 'payload': _payload(ring(name: 'Ana'))};
      final call = await incomingCallFor(data, await _store());

      expect(call.callerName, 'Ana');
      expect(call.callId, 'ring-7');
    });

    test('a content-free envelope keeps the ring id, not the name', () async {
      final data = {'kind': 'call', 'payload': _payload(ring())};
      final call = await incomingCallFor(data, await _store());

      expect(call.callerName, unknownCaller);
      expect(call.callId, 'ring-7');
    });

    test(
      'an envelope that does not open keeps the current fallbacks',
      () async {
        final call = await incomingCallFor({
          'kind': 'call',
          'payload': 'garbage',
        }, await _store());

        expect(call.callerName, unknownCaller);
        expect(call.callId, isNotEmpty);
      },
    );
  });

  group('tapPayloadFor', () {
    test('a message envelope yields a channel-only target', () async {
      final envelope = await openPushPayload(
        _payload(_envelope(channelId: 'c9')),
        await _store(),
      );
      final target = NotificationTarget.decode(tapPayloadFor(envelope));

      expect(target!.channelId, 'c9');
      expect(target.origin, isNull);
    });

    test('an envelope with no channel yields no payload', () async {
      final envelope = await openPushPayload(
        _payload({
          'domain': 'slim-m.push.v1',
          'version': 1,
          'event': 'admin_alert',
        }),
        await _store(),
      );

      expect(tapPayloadFor(envelope), isNull);
    });
  });
}
