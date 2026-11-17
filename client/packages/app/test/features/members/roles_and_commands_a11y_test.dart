// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/widgets/member_moderate_roles.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _app(Widget child, {List<Override> overrides = const []}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    );

void main() {
  testWidgets('collapsed Roles row announces the held roles', (tester) async {
    final handle = tester.ensureSemantics();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const roles = [
      api.Role(
        id: 'r1',
        name: 'Moderators',
        permissions: 0,
        isEveryone: false,
        createdAt: 0,
      ),
      api.Role(
        id: 'r2',
        name: 'Djs',
        permissions: 0,
        isEveryone: false,
        createdAt: 0,
      ),
    ];
    await tester.pumpWidget(
      _app(
        MemberModerateRoles(
          roles: roles,
          member: const api.UserProfile(
            id: 'maya',
            username: 'maya',
            displayName: 'maya',
            createdAt: 0,
            roleIds: ['r1', 'r2'],
          ),
          ladder: const RoleLadder(permissions: 0),
          compact: true,
          onChanged: (_, _) {},
        ),
      ),
    );
    await tester.pump();
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('^Roles')));
    final data = node.getSemanticsData();
    final text = '${data.label} ${data.value}';
    expect(text, contains('Moderators'));
    expect(text, contains('Djs'));
    handle.dispose();
  });
}
