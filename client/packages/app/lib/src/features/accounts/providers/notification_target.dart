// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which server and channel a desktop notification was posted for, carried as its payload.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:convert';

class NotificationTarget {
  const NotificationTarget({required this.origin, required this.channelId});

  final String origin;
  final String channelId;

  String encode() => jsonEncode({'o': origin, 'c': channelId});

  /// Null for a payload this client did not write, such as none at all.
  static NotificationTarget? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final json = jsonDecode(payload);
      if (json is! Map) return null;
      final origin = json['o'];
      final channelId = json['c'];
      if (origin is! String || channelId is! String) return null;
      if (origin.isEmpty || channelId.isEmpty) return null;
      return NotificationTarget(origin: origin, channelId: channelId);
    } on FormatException {
      return null;
    }
  }
}
