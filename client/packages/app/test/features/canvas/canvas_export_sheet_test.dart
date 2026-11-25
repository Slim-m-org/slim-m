// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Export canvas" sheet: its form, the one id every attempt sends, each outcome's words and buttons, and the toast that opens the copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/widgets/canvas_export_sheet.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';
import '../../support/canvas_export_rig.dart';

void main() {
  exportTest(
    'the name starts as "<source> canvas" and the sheet says what it does',
    (tester) async {
      final rig = await exportRig(tester, answer: (_) => exportedResponse());
      await rig.open();

      expect(find.text('Export canvas'), findsOneWidget);
      expect(find.text('Export to canvas channel'), findsOneWidget);
      expect(
        find.text('Copies this board into a new canvas channel.'),
        findsOneWidget,
      );
      expect(exportName(tester), 'minecraft canvas');
      expect(find.text('Voice call'), findsOneWidget);
    },
  );

  exportTest(
    'a very long source name is cut so the default still fits the name limit',
    (tester) async {
      final long = 'x' * 64;
      expect(exportDefaultName(long).length, lessThanOrEqualTo(64));
      expect(exportDefaultName(long).endsWith(' canvas'), isTrue);
      expect(exportDefaultName('minecraft'), 'minecraft canvas');
    },
  );

  exportTest('"Clear this canvas after" is only offered with MANAGE_CANVAS', (
    tester,
  ) async {
    final without = await exportRig(
      tester,
      answer: (_) => exportedResponse(),
      channelPermissions: 0,
    );
    await without.open();
    expect(find.text('Clear this canvas after'), findsNothing);
    expect(find.text('Export'), findsOneWidget);
  });

  exportTest(
    'turning the clear on makes the button danger-toned and renames it',
    (tester) async {
      final rig = await exportRig(tester, answer: (_) => exportedResponse());
      await rig.open();
      expect(
        exportButtonWidget(tester, 'Export').variant,
        AppButtonVariant.primary,
      );
      expect(
        find.text('Removes everything here once the copy is made.'),
        findsOneWidget,
      );

      await tester.tap(
        find.byWidgetPredicate(
          (w) =>
              w is AppToggle &&
              w.semanticLabel == 'Clear this canvas after exporting',
        ),
      );
      await pumpFrames(tester, frames: 30);

      expect(
        exportButtonWidget(tester, 'Export and clear').variant,
        AppButtonVariant.danger,
      );
    },
  );

  exportTest("the copy is filed under the source's own category by default", (
    tester,
  ) async {
    final rig = await exportRig(
      tester,
      answer: (_) => exportedResponse(),
      source: {'category_id': 'gamers'},
    );
    await rig.open();
    expect(find.text('Gamers'), findsOneWidget);
    await rig.submit('Export');

    expect(rig.bodies.single['category_id'], 'gamers');
  });

  exportTest('a restricted source says who will see the copy', (tester) async {
    final rig = await exportRig(
      tester,
      answer: (_) => exportedResponse(),
      source: {'restricted': true},
    );
    await rig.open();
    expect(
      find.text('Visible to the same people as this channel.'),
      findsOneWidget,
    );
  });

  exportTest(
    'without permission to manage channels the sheet explains and offers no export',
    (tester) async {
      final rig = await exportRig(
        tester,
        answer: (_) => exportedResponse(),
        permissions: 0,
      );
      await rig.open();

      expect(
        find.text('You need permission to manage channels to export.'),
        findsOneWidget,
      );
      expect(exportButton('Export'), findsNothing);
      expect(exportButton('Cancel'), findsOneWidget);
    },
  );

  exportTest('Cancel and Export sit side by side, equal and inside the sheet', (
    tester,
  ) async {
    final rig = await exportRig(
      tester,
      answer: (_) => exportedResponse(),
      size: const Size(390, 844),
    );
    await rig.open();

    final cancel = tester.getRect(exportButton('Cancel'));
    final export = tester.getRect(exportButton('Export'));
    expect((cancel.top - export.top).abs(), lessThan(1));
    expect((cancel.width - export.width).abs(), lessThan(1));
    expect(cancel.right, lessThan(export.left));
    expect(export.right, lessThanOrEqualTo(390 - AppSpacing.s16 + 1));
    expect(cancel.left, greaterThanOrEqualTo(AppSpacing.s16 - 1));
  });

  exportTest(
    'every attempt from one sheet sends the same id, and a reopened sheet a new one',
    (tester) async {
      final rig = await exportRig(
        tester,
        answer: (_) => refusedResponse(500, 'internal error'),
      );
      await rig.open();
      await rig.submit('Export');
      await rig.submit('Try again');
      await tester.tap(find.text('Cancel'));
      await pumpFrames(tester, frames: 30);
      await rig.open();
      await rig.submit('Export');

      expect(rig.bodies, hasLength(3));
      expect(rig.bodies[1]['id'], rig.bodies[0]['id']);
      expect(rig.bodies[2]['id'], isNot(rig.bodies[0]['id']));
      expect(rig.bodies[0]['name'], 'minecraft canvas');
      expect(rig.bodies[0]['clear_source'], false);
      expect(rig.bodies[0]['voice_enabled'], false);
      expect(rig.bodies[0].containsKey('category_id'), isTrue);
    },
  );

  exportTest('an error answer says nothing was changed and offers Try again', (
    tester,
  ) async {
    final rig = await exportRig(
      tester,
      answer: (_) => refusedResponse(409, 'this canvas is full'),
    );
    await rig.open();
    await rig.submit('Export');

    expect(
      find.text('This canvas is full. Nothing was changed.'),
      findsOneWidget,
    );
    expect(exportButton('Try again'), findsOneWidget);
  });

  exportTest(
    'no answer says it will not make a second copy and keeps the form still',
    (tester) async {
      final rig = await exportRig(
        tester,
        answer: (_) => throw http.ClientException('connection refused'),
      );
      await rig.open();
      await rig.submit('Export');

      expect(
        find.text(
          "Couldn't reach the server. Try again; it won't make a second copy.",
        ),
        findsOneWidget,
      );
      expect(exportButton('Try again'), findsOneWidget);
      final input = tester.widget<AppInput>(
        find.byWidgetPredicate(
          (w) => w is AppInput && w.placeholder == 'Channel name',
        ),
      );
      expect(
        input.enabled,
        isFalse,
        reason: 'the retry must be the same request',
      );
    },
  );

  exportTest('a board too big to export offers Cancel and nothing to try', (
    tester,
  ) async {
    final rig = await exportRig(
      tester,
      answer: (_) => refusedResponse(
        409,
        'This canvas is too big to export.',
        code: api.CanvasExportRefusal.tooLarge,
      ),
    );
    await rig.open();
    await rig.submit('Export');

    expect(find.text('This canvas is too big to export.'), findsOneWidget);
    expect(exportButton('Cancel'), findsOneWidget);
    expect(exportButton('Try again'), findsNothing);
    expect(exportButton('Export'), findsNothing);
  });

  exportTest('a board already being exported says so and offers Try again', (
    tester,
  ) async {
    final rig = await exportRig(
      tester,
      answer: (_) => refusedResponse(
        409,
        'This canvas is being exported already.',
        code: api.CanvasExportRefusal.busy,
      ),
    );
    await rig.open();
    await rig.submit('Export');

    expect(find.text('This canvas is being exported already.'), findsOneWidget);
    expect(exportButton('Try again'), findsOneWidget);
  });

  exportTest(
    'success closes the sheet and toasts with Open, which goes to the copy',
    (tester) async {
      final rig = await exportRig(
        tester,
        answer: (_) => exportedResponse(spared: 2),
      );
      await rig.open();
      await rig.submit('Export');

      expect(find.text('Export canvas'), findsNothing);
      final toast = rig.toasts.single;
      expect(
        toast.message,
        'Exported to minecraft canvas. 2 locked items stayed.',
      );
      expect(toast.actionLabel, 'Open');
      toast.onAction!();
      await pumpFrames(tester, frames: 10);
      expect(
        rig.router.routerDelegate.currentConfiguration.uri.path,
        Routes.channel('new-channel'),
      );
    },
  );

  exportTest('success after a retry toasts the same way', (tester) async {
    var calls = 0;
    final rig = await exportRig(
      tester,
      answer: (_) => ++calls == 1
          ? throw http.ClientException('lost')
          : exportedResponse(),
    );
    await rig.open();
    await rig.submit('Export');
    await rig.submit('Try again');

    expect(rig.toasts.single.message, 'Exported to minecraft canvas.');
    expect(rig.toasts.single.actionLabel, 'Open');
    expect(rig.bodies[1]['id'], rig.bodies[0]['id']);
  });
}
