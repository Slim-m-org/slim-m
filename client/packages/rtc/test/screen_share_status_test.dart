// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ScreenShareView` hands its placeholder to the app's scope, by status.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/screen_share_view.dart';

void main() {
  late lk.Room room;
  setUp(() => room = lk.Room());
  tearDown(() => room.dispose());

  testWidgets('a share with no publication yet asks for the loading card', (
    tester,
  ) async {
    final seen = <ScreenShareStatus>[];
    await tester.pumpWidget(
      MaterialApp(
        home: ScreenShareStatusScope(
          builder: (context, status) {
            seen.add(status);
            return const Text('card');
          },
          child: ScreenShareView(room: room, identity: 'bob'),
        ),
      ),
    );
    expect(find.text('card'), findsOneWidget);
    expect(seen, everyElement(ScreenShareStatus.loading));
  });

  testWidgets('without a scope the loading dots stay', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ScreenShareView(room: room, identity: 'bob')),
    );
    expect(find.bySemanticsLabel('Loading screen share'), findsOneWidget);
  });
}
