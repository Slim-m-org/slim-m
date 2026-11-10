// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join gate as a waiting member sees it: the banner above the shell, and the rules sheet behind its button.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import '../ui_snapshot_support.dart';
import 'members_review_support.dart';

const _rules =
    'Be kind, and assume good intent.\n'
    'No spam, ads or self-promotion without asking.\n'
    'Keep spoilers in #spoilers.\n'
    'Ask a moderator if you are unsure.';

enum _Accept { notYet, hangs, refused }

Override _waiting([_Accept accept = _Accept.notYet]) => reviewApi((request) {
  final path = request.url.path;
  if (path == '/space/rules') {
    return reviewJson({
      'rules': _rules,
      'rules_channel_id': 'c-general',
      'pending': true,
    });
  }
  if (path == '/space/rules/accept') {
    return switch (accept) {
      _Accept.hangs => Completer<http.Response>().future,
      _Accept.refused => reviewJson({'error': 'the server is busy'}, 503),
      _Accept.notYet => null,
    };
  }
  return null;
});

Future<void> _openRules(ReviewRig rig) => rig.tapText('Read the rules');

Future<void> _accept(ReviewRig rig) async {
  await _openRules(rig);
  await rig.tapText('I accept the rules');
}

void main() {
  setUpAll(loadRealFonts);

  reviewCase('banner-rules-gate', overrides: () => [_waiting()]);

  reviewCase(
    'sheet-rules-gate',
    state: 'rules',
    overrides: () => [_waiting()],
    drive: _openRules,
  );

  reviewCase(
    'sheet-rules-gate',
    state: 'loading',
    overrides: () => [_waiting(_Accept.hangs)],
    drive: _accept,
  );

  reviewCase(
    'sheet-rules-gate',
    state: 'accept-error',
    overrides: () => [_waiting(_Accept.refused)],
    drive: _accept,
  );
}
