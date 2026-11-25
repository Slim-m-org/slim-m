// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A frame this client cannot read asks for a resync once per window, not once per message.
library;

import 'package:test/test.dart';
import 'package:slimm_api/api.dart';

const _unreadable = '{"type":"message.created","message":{}}';

void main() {
  test('a repeating unreadable frame asks for one resync per window', () {
    var now = DateTime(2026, 11, 24);
    final throttle = ParseResyncThrottle(now: () => now);

    final first = ServerEvent.parse(_unreadable, throttle: throttle);
    final again = ServerEvent.parse(_unreadable, throttle: throttle);
    now = now.add(const Duration(seconds: 31));
    final later = ServerEvent.parse(_unreadable, throttle: throttle);

    expect(first, isA<ErrorEvent>());
    expect(again, isNull);
    expect(later, isA<ErrorEvent>());
  });

  test('each frame type has its own window', () {
    final throttle = ParseResyncThrottle();
    ServerEvent.parse(_unreadable, throttle: throttle);

    final other = ServerEvent.parse(
      '{"type":"channel.created","channel":5}',
      throttle: throttle,
    );

    expect(other, isA<ErrorEvent>());
  });

  test('without a throttle every unreadable frame still asks', () {
    expect(ServerEvent.parse(_unreadable), isA<ErrorEvent>());
    expect(ServerEvent.parse(_unreadable), isA<ErrorEvent>());
  });
}
