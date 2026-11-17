// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The add-a-column sheet: searchable, leaves out what the grid already has,
/// scrolls inside a capped frame, and can be closed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/overwrite_target_picker.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

api.Role _role(String n, {bool everyone = false}) => api.Role(
  id: 'r-$n',
  name: n,
  permissions: 0,
  isEveryone: everyone,
  createdAt: 0,
);

api.UserProfile _member(String id, String name, {bool bot = false}) =>
    api.UserProfile(
      id: id,
      username: name.toLowerCase(),
      displayName: name,
      createdAt: 0,
      isBot: bot,
    );

Future<void> _open(
  WidgetTester tester, {
  Set<String> taken = const {},
  Size size = const Size(900, 800),
  void Function(Object?)? onResult,
  int roleCount = 30,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        rolesProvider.overrideWith(
          (ref) async => [
            _role('everyone', everyone: true),
            for (var i = 0; i < roleCount; i++) _role('role$i'),
          ],
        ),
        membersProvider.overrideWith(
          (ref) async => [
            _member('m1', 'Nadia'),
            _member('b1', 'Casino', bot: true),
            _member('m2', 'Omar'),
          ],
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Builder(
          builder: (context) => TextButton(
            key: const Key('open'),
            onPressed: () async {
              final result = await showAppSheet<Object>(
                context,
                builder: (_) => OverwriteTargetPicker(taken: taken),
              );
              onResult?.call(result);
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('hides everyone and taken targets', (tester) async {
    await _open(tester, taken: {'role:r-role0', 'member:m1'});
    expect(
      find.byKey(const Key('target-picker-role-r-everyone')),
      findsNothing,
    );
    expect(find.byKey(const Key('target-picker-role-r-role0')), findsNothing);
    expect(find.byKey(const Key('target-picker-role-r-role1')), findsOneWidget);
    expect(find.byKey(const Key('target-picker-member-m1')), findsNothing);
  });

  testWidgets('search filters roles and members', (tester) async {
    await _open(tester);
    await tester.enterText(
      find.byKey(const Key('target-picker-input')),
      'omar',
    );
    await tester.pump();
    expect(find.byKey(const Key('target-picker-member-m2')), findsOneWidget);
    expect(find.byKey(const Key('target-picker-member-m1')), findsNothing);
    expect(find.byKey(const Key('target-picker-role-r-role1')), findsNothing);
    await tester.enterText(find.byKey(const Key('target-picker-input')), 'zzz');
    await tester.pump();
    expect(find.byKey(const Key('target-picker-empty')), findsOneWidget);
  });

  testWidgets('the list is capped and the sheet stays inside the window', (
    tester,
  ) async {
    await _open(tester);
    final list = tester.getRect(find.byKey(const Key('target-picker-list')));
    expect(list.height, lessThanOrEqualTo(800 * 0.6 + 0.5));
    expect(list.bottom, lessThan(800));
  });

  testWidgets('choosing a row pops it and close pops null', (tester) async {
    Object? result = 'unset';
    await _open(tester, onResult: (r) => result = r);
    await tester.enterText(
      find.byKey(const Key('target-picker-input')),
      'omar',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('target-picker-member-m2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect((result as api.UserProfile).id, 'm2');

    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('target-picker-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(result, isNull);
  });

  testWidgets('phone width opens as a sheet without the close button', (
    tester,
  ) async {
    await _open(tester, size: const Size(390, 844));
    expect(find.byKey(const Key('target-picker-close')), findsNothing);
    expect(find.byKey(const Key('target-picker-role-r-role1')), findsOneWidget);
  });

  testWidgets('bots are listed apart from people, each marked Bot', (
    tester,
  ) async {
    await _open(tester, roleCount: 2);
    Finder inRow(String id, String text) => find.descendant(
      of: find.byKey(Key('target-picker-member-$id')),
      matching: find.text(text),
    );
    expect(inRow('b1', 'BOT'), findsOneWidget);
    expect(inRow('m1', 'BOT'), findsNothing);
    final botsLabel = tester.getRect(find.text('BOTS')).top;
    expect(
      tester.getRect(find.byKey(const Key('target-picker-member-m2'))).top,
      lessThan(botsLabel),
      reason: 'people come first, bots under their own label',
    );
    expect(
      tester.getRect(find.byKey(const Key('target-picker-member-b1'))).top,
      greaterThan(botsLabel),
    );
  });

  for (final size in const [Size(900, 800), Size(390, 844)]) {
    testWidgets('role and member names start on one line at $size', (
      tester,
    ) async {
      await _open(tester, roleCount: 2, size: size);
      expect(
        tester.getTopLeft(find.text('role1')).dx,
        tester.getTopLeft(find.text('Nadia')).dx,
      );
    });
  }
}
