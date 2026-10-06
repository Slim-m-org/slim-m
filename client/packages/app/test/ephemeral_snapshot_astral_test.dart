// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/ephemeral_report.dart';

api.EphemeralMessage _message(String content) => api.EphemeralMessage(
  id: 'e1',
  channelId: 'c1',
  authorId: 'bot-1',
  authorDisplayName: 'Helper',
  content: content,
  inReplyToId: 'm1',
  createdAt: 1,
  attachments: const [],
  embeds: const [],
);

bool _hasLoneSurrogate(String s) {
  final u = s.codeUnits;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= u.length || u[i + 1] < 0xDC00 || u[i + 1] > 0xDFFF) {
        return true;
      }
      i++;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return true;
    }
  }
  return false;
}

void main() {
  test('a cut inside an emoji never leaves a lone surrogate', () {
    final text = '${'a' * (maxEphemeralSnapshotChars - 1)}\u{1F600}tail';
    final snap = ephemeralSnapshot(_message(text));
    final wire = jsonEncode({'snapshot': snap});
    expect(_hasLoneSurrogate(snap), isFalse);
    expect(wire.contains(r'\ud83d'), isFalse);
  });

  test('astral text is counted in code points, as the server does', () {
    final snap = ephemeralSnapshot(_message('\u{1F600}' * 3000));
    expect(snap.runes.length, 3000);
  });
}
