// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:test/test.dart';
import 'package:slimm_api/api.dart' as api;

void main() {
  test('Message.fromJson reads repost_of_author_id, null when absent', () {
    final base = {
      'id': 'm1',
      'channel_id': 'c1',
      'author_id': 'bot',
      'author_display_name': 'starboard',
      'seq': 1,
      'content': 'hi',
      'created_at': 0,
    };

    expect(
      api.Message.fromJson({...base, 'repost_of_author_id': 'u9'})
          .repostOfAuthorId,
      'u9',
    );
    expect(api.Message.fromJson(base).repostOfAuthorId, isNull);
  });
}
