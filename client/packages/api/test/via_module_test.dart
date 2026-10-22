// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:test/test.dart';
import 'package:slimm_api/api.dart' as api;

void main() {
  final base = {
    'id': 'm1',
    'channel_id': 'c1',
    'author_id': 'u1',
    'author_display_name': 'Nia',
    'seq': 1,
    'content': 'hi',
    'created_at': 0,
  };

  test('Message.fromJson reads via_module, null when absent', () {
    final posted = api.Message.fromJson({
      ...base,
      'via_module': {'id': 'ticker', 'name': 'Ticker', 'background': true},
    });
    expect(posted.viaModule?.id, 'ticker');
    expect(posted.viaModule?.name, 'Ticker');
    expect(posted.viaModule?.background, isTrue);
    expect(api.Message.fromJson(base).viaModule, isNull);
    expect(
        api.Message.fromJson({...base, 'via_module': null}).viaModule, isNull);
  });
}
