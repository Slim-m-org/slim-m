// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the "Export canvas" sheet says after an export: items left on the original, and an unknown outcome that keeps the form still.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/providers/canvas_export.dart';

import '../../support/canvas_export_rig.dart';

void main() {
  exportTest('items that could not be copied are named next to the locked ones', (
    tester,
  ) async {
    final rig = await exportRig(
      tester,
      answer: (_) => exportedResponse(spared: 2, left: 3),
    );
    await rig.open();
    await rig.submit('Export');

    expect(
      rig.toasts.single.message,
      "Exported to minecraft canvas. 2 locked items stayed. 3 items couldn't be copied and stayed on the original.",
    );
  });

  exportTest('one item left behind reads in the singular', (tester) async {
    final rig = await exportRig(
      tester,
      answer: (_) => exportedResponse(left: 1),
    );
    await rig.open();
    await rig.submit('Export');

    expect(
      rig.toasts.single.message,
      "Exported to minecraft canvas. 1 item couldn't be copied and stayed on the original.",
    );
  });

  exportTest(
    'busy after a lost answer is unknown, keeps the form still, then succeeds',
    (tester) async {
      var calls = 0;
      final rig = await exportRig(
        tester,
        answer: (_) {
          calls++;
          if (calls == 1) throw http.ClientException('lost');
          if (calls == 2) {
            return refusedResponse(
              409,
              'This canvas is being exported already.',
              code: api.CanvasExportRefusal.busy,
            );
          }
          return exportedResponse();
        },
      );
      await rig.open();
      await rig.submit('Export');
      await rig.submit('Try again');

      expect(
        find.text(CanvasExportFailure.stillFinishingMessage),
        findsOneWidget,
      );
      expect(find.text(CanvasExportFailure.busyMessage), findsNothing);
      expect(exportButton('Try again'), findsOneWidget);
      expect(exportInputEnabled(tester), isFalse);

      await rig.submit('Try again');
      expect(rig.toasts.single.message, 'Exported to minecraft canvas.');
      expect(rig.bodies.map((b) => b['id']).toSet(), hasLength(1));
    },
  );

  exportTest('a 429 after a lost answer never says nothing was changed', (
    tester,
  ) async {
    var calls = 0;
    final rig = await exportRig(
      tester,
      answer: (_) => ++calls == 1
          ? throw http.ClientException('lost')
          : refusedResponse(429, 'slow down'),
    );
    await rig.open();
    await rig.submit('Export');
    await rig.submit('Try again');

    expect(
      find.text(CanvasExportFailure.stillFinishingMessage),
      findsOneWidget,
    );
    expect(find.textContaining('Nothing was changed'), findsNothing);
    expect(exportButton('Try again'), findsOneWidget);
    expect(exportInputEnabled(tester), isFalse);
  });
}
