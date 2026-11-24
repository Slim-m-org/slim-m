// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which server and channel a desktop notification was posted for, carried as its payload.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

import 'dart:convert';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

class NotificationTarget {
  const NotificationTarget({this.origin, required this.channelId});

  /// Null when the push could not name the account; the channel's owner is looked up instead.
  final String? origin;
  final String channelId;

  String encode() => jsonEncode({'o': ?origin, 'c': channelId});

  /// Null for a payload this client did not write, such as none at all.
  static NotificationTarget? decode(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final json = jsonDecode(payload);
      if (json is! Map) return null;
      final origin = json['o'];
      final channelId = json['c'];
      if (channelId is! String || channelId.isEmpty) return null;
      if (origin != null && (origin is! String || origin.isEmpty)) return null;
      return NotificationTarget(
        origin: origin as String?,
        channelId: channelId,
      );
    } on FormatException catch (error, stack) {
      AppLog.swallowed(
        LogTag.auth,
        'A notification carried a target that could not be read; ignoring it',
        error,
        stack,
      );
      return null;
    }
  }
}
