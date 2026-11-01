// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [cappedChannelWindow] is the one bound `channel_history.dart` and any
/// future store or extras sweep must agree on, so it is tested on its own
/// rather than only indirectly through `channel_history_test.dart`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/providers/retention_policy.dart';

void main() {
  test('a window under the ceiling is returned unchanged', () {
    expect(cappedChannelWindow(0), 0);
    expect(cappedChannelWindow(200), 200);
    expect(
      cappedChannelWindow(channelWindowCeiling - 1),
      channelWindowCeiling - 1,
    );
  });

  test('a window at or past the ceiling is clamped to it', () {
    expect(cappedChannelWindow(channelWindowCeiling), channelWindowCeiling);
    expect(cappedChannelWindow(channelWindowCeiling + 1), channelWindowCeiling);
    expect(
      cappedChannelWindow(channelWindowCeiling * 10),
      channelWindowCeiling,
    );
  });
}
