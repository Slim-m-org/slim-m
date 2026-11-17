// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The preview rail lists channels in the order the server sent them, which
/// already breaks position ties the way the real rail does.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/role_preview/widgets/role_preview_rail.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

void main() {
  testWidgets('channels with one position keep the server order', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final names = [for (var i = 0; i < 40; i++) 'ch-${(i * 7) % 40}'];
    final preview = api.RolePreview(
      roleId: 'r',
      permissions: 0,
      categories: const [],
      channels: [
        for (final name in names)
          api.RolePreviewChannel(
            id: name,
            name: name,
            kind: 'text',
            position: 0,
            permissions: 0,
            restricted: false,
          ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: RolePreviewRail(
            preview: preview,
            selectedId: null,
            onOpen: (_) {},
          ),
        ),
      ),
    );
    await pumpFrames(tester);

    final tops = [for (final n in names) tester.getTopLeft(find.text(n)).dy];
    expect(tops, [...tops]..sort());
  });
}
