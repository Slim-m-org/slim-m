// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/screens/channel_settings_general_section.dart';
import 'package:slimm_design_system/design_system.dart';

import 'channel_management_harness.dart';

void main() {
  testWidgets('200 astral characters is 200 chars, under the 256 cap', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      harness(
        SingleChildScrollView(
          child: ChannelGeneralSection(channel: channel('c1', 'general')),
        ),
        handler: (_) => http.Response('{}', 200),
      ),
    );
    await tester.pumpAndSettle();
    final topic = find.byWidgetPredicate(
      (w) => w is AppInput && w.semanticLabel == 'Channel description',
    );
    await tester.enterText(
      find.descendant(of: topic, matching: find.byType(EditableText)),
      List.filled(200, '\u{1F600}').join(),
    );
    await tester.pump();
    final counter = tester
        .widgetList<Text>(find.textContaining('/256'))
        .map((t) => t.data)
        .toList();
    expect(counter, ['200/256']);
    final save = tester.widget<AppButton>(find.byType(AppButton));
    expect(save.disabled, isFalse);
  });
}
