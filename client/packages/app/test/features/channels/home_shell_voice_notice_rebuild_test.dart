// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice notice is for its banner; the shell holds the provider alive for
/// the session but must not rebuild itself when a notice comes or goes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_notice_controller.dart';
import 'package:slimm_app/src/screens/home_shell.dart';

import '../settings/home_shell_harness.dart';

class _Notices extends VoiceNoticeController {
  @override
  VoiceNoticeItem? build() => null;

  void put(VoiceNoticeItem? item) => state = item;
}

void main() {
  testWidgets('a notice coming and going does not rebuild the shell', (
    tester,
  ) async {
    final s = setup(
      httpClient: quietClient(),
      signedIn: true,
      extraOverrides: [voiceNoticeProvider.overrideWith(_Notices.new)],
    );
    await pumpAtWidth(tester, s.container, 1200);
    final notices = s.container.read(voiceNoticeProvider.notifier) as _Notices;

    var shellBuilds = 0;
    debugOnRebuildDirtyWidget = (element, _) {
      if (element.widget is HomeShell) shellBuilds++;
    };
    addTearDown(() => debugOnRebuildDirtyWidget = null);
    notices.put(const VoiceNoticeItem(channelId: 'c1', text: 'Ada joined #a'));
    await tester.pump();
    notices.put(null);
    await tester.pump();
    debugOnRebuildDirtyWidget = null;

    expect(shellBuilds, 0);
    await teardown(tester, s.container, s.db);
  });
}
