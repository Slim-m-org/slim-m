// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The roster's live refetch is held by the shell, not only by the member
/// pane: with no pane open, someone who had just joined was missing from the
/// group message picker until a reload.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';

import '../settings/home_shell_harness.dart';

void main() {
  testWidgets(
    'at phone width, with no member pane, the roster still follows joins',
    (tester) async {
      final s = setup(signedIn: true);
      await pumpAtWidth(tester, s.container, 390, location: '/channels');
      await tester.pump(const Duration(milliseconds: 100));

      expect(s.container.exists(memberModerationWatcherProvider), isTrue);
      await teardown(tester, s.container, s.db);
    },
  );
}
