// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Addons group (Modules, Bots, Webhooks) exists only for MANAGE_SERVER.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/widgets/settings_panes.dart';
import 'package:slimm_app/src/widgets/space_settings_section.dart';

Future<List<SettingsPaneGroup>> _groups(WidgetTester tester, int mine) async {
  late List<SettingsPaneGroup> groups;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myPermissionsProvider.overrideWithValue(mine),
        myVisibleChannelsProvider.overrideWith((ref) async => <api.Channel>[]),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            groups = spaceSettingsPaneGroups(context, ref);
            return const SizedBox.shrink();
          },
        ),
      ),
    ),
  );
  return groups;
}

List<String> _addons(List<SettingsPaneGroup> groups) => [
  for (final group in groups)
    if (group.label == 'Addons')
      for (final pane in group.panes) pane.label,
];

void main() {
  testWidgets('MANAGE_SERVER sees Modules, Bots and Webhooks', (tester) async {
    final groups = await _groups(tester, Perm.manageServer);
    expect(_addons(groups), ['Modules', 'Bots', 'Webhooks']);
  });

  testWidgets('without MANAGE_SERVER the Addons group is gone whole', (
    tester,
  ) async {
    final groups = await _groups(tester, Perm.manageRoles | Perm.createInvite);
    expect(_addons(groups), isEmpty);
    expect(groups.where((g) => g.label == 'Addons'), isEmpty);
  });
}
