// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The client's list of standard shortcodes a custom emoji may not take must
/// be the server's, or the form allows what the server then refuses.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/emoji/widgets/standard_emoji.dart';

void main() {
  test('the client and the server refuse the same standard names', () {
    final server = File(
      '../../../crates/slimm-server/src/emoji/builtin_names.txt',
    ).readAsLinesSync().where((line) => line.isNotEmpty).toList();

    expect(server, isNotEmpty);
    expect(server.toSet(), standardEmojiNames);
    expect(isStandardEmojiName('bug'), isTrue);
    expect(isStandardEmojiName('party_parrot'), isFalse);
  });
}
