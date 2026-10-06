// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel deleted while its row is held must not break the carried copy.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/channel_rail_reorder.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Channel _channel(String id) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

void main() {
  testWidgets('channel vanishing mid-hold does not throw on overlay rebuild', (
    tester,
  ) async {
    final sections = ValueNotifier<List<ChannelSection>>([
      (null, [_channel('a'), _channel('b'), _channel('c')]),
    ]);
    final brightness = ValueNotifier(Brightness.light);
    await tester.pumpWidget(
      ValueListenableBuilder(
        valueListenable: brightness,
        builder: (context, b, _) => MaterialApp(
          theme: buildTheme(
            b,
            b == Brightness.light ? AppTokens.light : AppTokens.dark,
          ),
          home: Scaffold(
            body: SizedBox(
              height: 400,
              child: SingleChildScrollView(
                child: ValueListenableBuilder(
                  valueListenable: sections,
                  builder: (context, s, _) => ReorderableChannelRows(
                    sections: s,
                    canManage: true,
                    onReorder: (_) {},
                    rowBuilder: (channel, _) =>
                        SizedBox(height: 48, child: Text(channel.id)),
                    headerBuilder: (c) => Text('header:${c?.id}'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(tester.getCenter(find.text('a')));
    await tester.pump(kLongPressTimeout + kPressTimeout);
    await gesture.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(tester.takeException(), isNull, reason: 'lift itself is fine');

    sections.value = [
      (null, [_channel('b'), _channel('c')]),
    ];
    await tester.pump();
    brightness.value = Brightness.dark;
    await tester.pump();
    expect(
      tester.takeException(),
      isNull,
      reason: 'overlay rebuild after channel removed',
    );
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
