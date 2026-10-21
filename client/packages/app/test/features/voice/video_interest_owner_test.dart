// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two canvas panes for one channel (the page fade between them) each declare
/// their own video interest; one leaving must not clear the other's.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/video_interest_relay.dart';

void main() {
  test('a pane leaving does not clear the interest of the one that stays', () {
    final applied = <Set<String>?>[];
    final relay = VideoInterestRelay(applied.add);
    final leaving = Object();
    final staying = Object();

    relay.declare({'camera:a'}, owner: staying);
    relay.declare({'camera:b'}, owner: leaving);
    relay.declare(null, owner: leaving);

    expect(relay.resolved, {'camera:a'});
    expect(applied.last, {'camera:a'});
  });

  test('every owner leaving empties the interest', () {
    final relay = VideoInterestRelay((_) {});
    final a = Object();
    final b = Object();
    relay.declare({'camera:a'}, owner: a);
    relay.declare({'camera:b'}, owner: b);
    relay.declare(null, owner: a);
    relay.declare(null, owner: b);

    expect(relay.resolved, isEmpty);
  });

  test('a lone caller that names no owner behaves as before', () {
    final relay = VideoInterestRelay((_) {});
    relay.declare({'camera:a'});
    expect(relay.resolved, {'camera:a'});
    relay.declare(null);
    expect(relay.resolved, isEmpty);
  });
}
