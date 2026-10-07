// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Client-generated identifiers.
library;

import 'dart:math';

import 'package:flutter/foundation.dart';

/// Generates the UUIDv7 that identifies a message and makes its send
/// idempotent. Time-ordered, which is what the server's storage assumes.
///
/// Shared by the ordinary send path and the poll composer, both of which
/// need a client-generated id before the server has ever seen the message.
String newMessageId() => _uuidV7();

/// The same generator for a report, which is idempotent by id the same way
/// a message is: the id is minted once per filing so a retry after an
/// uncertain failure replays the report rather than being refused as a
/// duplicate.
String newReportId() => _uuidV7();

/// The same generator for a canvas object, which is idempotent by id the same
/// way a message send is. Named separately so a call site says which stream it
/// belongs to.
String newCanvasObjectId() => _uuidV7();

/// The same generator for a canvas op (`remove`, `clear`, `restore`, `move`),
/// which is idempotent by id the same way a placement is.
String newCanvasOpId() => _uuidV7();

/// The same generator for an in-flight stroke preview session. Never a real
/// canvas object id: it only keys an ephemeral relay frame, and the object(s)
/// a finished stroke commits are minted separately by [newCanvasObjectId]
/// once the gesture ends.
String newCanvasDraftId() => _uuidV7();

/// The same generator for a channel create, minted once per sheet so a retry
/// after a lost response replays the first create.
String newChannelId() => _uuidV7();

/// The same generator for a category create, minted once per sheet.
String newCategoryId() => _uuidV7();

String _uuidV7() =>
    uuidV7At(DateTime.now().millisecondsSinceEpoch, Random.secure());

/// A UUIDv7 for the instant [now] in epoch milliseconds. Split out so a test
/// can pin the timestamp bytes, which is the part that differs on the web.
@visibleForTesting
String uuidV7At(int now, Random random) {
  // Compiled to JavaScript a shift sees only the low 32 bits, so the top two bytes come from a division.
  final high = now ~/ 0x100000000;
  final bytes = <int>[
    (high >> 8) & 0xff,
    high & 0xff,
    (now >> 24) & 0xff,
    (now >> 16) & 0xff,
    (now >> 8) & 0xff,
    now & 0xff,
    ...List<int>.generate(10, (_) => random.nextInt(256)),
  ];
  bytes[6] = (bytes[6] & 0x0f) | 0x70;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
