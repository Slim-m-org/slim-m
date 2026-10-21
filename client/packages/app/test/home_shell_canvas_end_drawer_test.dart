// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-097: a touch stroke that starts at the right edge of the open canvas
/// must not slide the member roster drawer over it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/settings/home_shell_harness.dart';

void main() {
  testWidgets(
    'an edge drag on the open canvas does not open the roster drawer',
    (tester) async {
      final s = setup(httpClient: quietClient(), signedIn: true);
      await MessageStore(s.db).upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
      ]);
      s.container.read(canvasOpenProvider.notifier).state = 'c1';
      await pumpAtWidth(tester, s.container, 500, location: '/channels/c1');
      expect(find.byType(CanvasSurface), findsOneWidget);

      final scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      final size = tester.view.physicalSize / tester.view.devicePixelRatio;
      final gesture = await tester.startGesture(Offset(size.width - 4, 300));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));

      expect(scaffold.isEndDrawerOpen, isFalse);

      await teardown(tester, s.container, s.db);
    },
  );
}
