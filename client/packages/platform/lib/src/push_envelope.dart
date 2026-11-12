// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens a sealed push envelope and decides what text it puts on a
/// notification. Mirrors `ios/NotificationService/PushEnvelope.swift`; the
/// shape's authority is `crates/slimm-server/src/push/envelope.rs`.
///
/// Pure Dart, so it runs in FCM's background isolate. Every failure is a null
/// answer: the caller then shows its generic line.
library;

import 'dart:convert';

import 'package:pinenacl/x25519.dart';

import 'device_push_keys.dart';
import 'key_store.dart';

/// Domain separation: a payload sealed to this device for another purpose
/// never reads as a notification.
const _expectedDomain = 'slim-m.push.v1';
const _expectedVersion = 1;

/// Generous over delivery latency, short enough to refuse a replayed payload.
const pushEnvelopeStaleAfter = Duration(minutes: 10);

const _optionalStrings = [
  'channel_id',
  'message_id',
  'sender',
  'channel',
  'body',
  'kind',
  'event',
  'device_name',
  'title',
];

/// Title, body and optional channel to show instead of the generic line.
class PushPreviewText {
  const PushPreviewText({
    required this.title,
    required this.body,
    this.channel,
  });
  final String title;
  final String body;

  /// The channel name without its `#`, null for a DM or thread reply.
  final String? channel;

  @override
  bool operator ==(Object other) =>
      other is PushPreviewText &&
      other.title == title &&
      other.body == body &&
      other.channel == channel;

  @override
  int get hashCode => Object.hash(title, body, channel);
}

/// The decrypted envelope. Only [decode] builds one.
class PushEnvelope {
  const PushEnvelope._(this._json);

  final Map<String, dynamic> _json;

  /// Null for anything this build should not act on, including an unknown
  /// domain or version and a field of the wrong type.
  static PushEnvelope? decode(List<int> plaintext) {
    try {
      final json = jsonDecode(utf8.decode(plaintext));
      if (json is! Map<String, dynamic>) return null;
      if (json['domain'] != _expectedDomain) return null;
      if (json['version'] != _expectedVersion) return null;
      for (final key in _optionalStrings) {
        if (json[key] != null && json[key] is! String) return null;
      }
      if (json['sent_at'] != null && json['sent_at'] is! int) return null;
      return PushEnvelope._(json);
    } on Object {
      return null;
    }
  }

  String? get channelId => _json['channel_id'] as String?;
  int? get sentAt => _json['sent_at'] as int?;

  /// An envelope with no `sent_at` is never stale: the field is additive.
  bool isStale(DateTime now) {
    final sentAt = this.sentAt;
    if (sentAt == null) return false;
    return now.millisecondsSinceEpoch - sentAt >
        pushEnvelopeStaleAfter.inMilliseconds;
  }

  /// What to show in place of the generic line, or null to keep it. Content-
  /// free envelopes and stale ones answer null, as on iOS.
  PushPreviewText? preview(DateTime now) {
    if (isStale(now)) return null;
    final kind = _json['kind'] as String?;
    final event = _json['event'] as String?;
    final body = _json['body'] as String?;
    final deviceName = _json['device_name'] as String?;
    final title = _json['title'] as String?;
    if (kind == 'security' && event == 'new_device_sign_in') {
      if (deviceName == null || deviceName.isEmpty) return null;
      return PushPreviewText(
        title: 'New sign-in',
        body: '$deviceName signed in to your account.',
      );
    }
    if (kind == 'security' && event == 'admin_alert') {
      if (title == null || title.isEmpty || body == null) return null;
      return PushPreviewText(title: title, body: body);
    }
    final sender = _json['sender'] as String?;
    if (sender == null || sender.isEmpty || body == null || body.isEmpty) {
      return null;
    }
    final channel = _json['channel'] as String?;
    return PushPreviewText(
      title: sender,
      body: body,
      channel: channel == null || channel.isEmpty ? null : channel,
    );
  }
}

/// The libsodium `crypto_box_seal_open` of [sealed] with the 32-byte X25519
/// [privateKey], or null when it does not open.
///
/// pinenacl skips the tag check for an empty plaintext; [PushEnvelope.decode]
/// refuses that, so it never reaches a notification.
Uint8List? openSealedBox(Uint8List sealed, Uint8List privateKey) {
  try {
    return SealedBox(PrivateKey(privateKey)).decrypt(sealed);
  } on Object {
    return null;
  }
}

/// Opens the base64 `payload` of a push with this device's key from [keys],
/// or null on any failure, including no key yet.
Future<PushEnvelope?> openPushPayload(
  String? payload,
  KeyStore keys, {
  String handle = devicePushKeyHandle,
}) async {
  if (payload == null) return null;
  try {
    final stored = await keys.read(handle);
    if (stored == null) return null;
    final seed = base64Decode(stored);
    if (seed.length != 32) return null;
    final plaintext = openSealedBox(base64Decode(payload), seed);
    return plaintext == null ? null : PushEnvelope.decode(plaintext);
  } on Object {
    return null;
  }
}
