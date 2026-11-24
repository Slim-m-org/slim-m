// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A category's Private switch and "Who can see this" still refresh what they
/// changed when they are dismissed before the request answers.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/view_access.dart';
import 'package:slimm_app/src/features/channels/widgets/category_private_section.dart';
import 'package:slimm_app/src/permissions.dart';

import '../../support/async_wait.dart';
import 'category_private_fixture.dart';

const _target = CategoryViewTarget('cat');

OverwriteServer _server() => OverwriteServer({
  '/categories/cat': [
    {'kind': 'role', 'id': 'everyone', 'allow': 0, 'deny': Perm.viewChannel},
    {'kind': 'role', 'id': 'mods', 'allow': Perm.viewChannel, 'deny': 0},
  ],
});

/// The section, which a test can unmount, beside a reader that stays.
Widget _scene(ValueNotifier<bool> shown) => Column(
  children: [
    ValueListenableBuilder<bool>(
      valueListenable: shown,
      builder: (context, on, _) => on
          ? const CategoryPrivateSection(categoryId: 'cat', name: 'Admin')
          : const SizedBox.shrink(),
    ),
    Consumer(
      builder: (context, ref, _) {
        ref.watch(_target.overwrites);
        return const SizedBox.shrink();
      },
    ),
  ],
);

int _reads(OverwriteServer server) =>
    server.requests.where((r) => r == 'GET /categories/cat/overwrites').length;

/// Pumps frames until the overwrites were read again: an invalidation only
/// refetches on the frame after it.
Future<void> _refetched(
  WidgetTester tester,
  OverwriteServer server, {
  required int after,
}) async {
  for (var i = 0; i < 200 && _reads(server) <= after; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
  expect(
    _reads(server),
    greaterThan(after),
    reason: 'the list was not refreshed',
  );
}

/// Waits for the write to reach the server without settling the tree, which
/// would run the held request's timeout.
Future<void> _putArrived(WidgetTester tester, OverwriteServer server) async {
  await tester.runAsync(() async {
    while (!server.requests.contains('PUT /categories/cat/overwrites')) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
}

void main() {
  testWidgets('removing a viewer refreshes the list after the section is '
      'gone', (tester) async {
    final server = _server();
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await pumpPrivate(tester, server, _scene(shown));
    final hold = server.holdWrites = Completer<void>();

    await tester.tap(find.bySemanticsLabel('Remove Mods'));
    await _putArrived(tester, server);
    final readsBefore = _reads(server);
    shown.value = false;
    await pumpFrames(tester);
    hold.complete();
    await _refetched(tester, server, after: readsBefore);

    expect(tester.takeException(), isNull);
  });

  testWidgets('turning Private on refreshes the list after the section is '
      'gone', (tester) async {
    final server = OverwriteServer({});
    final shown = ValueNotifier(true);
    addTearDown(shown.dispose);
    await pumpPrivate(tester, server, _scene(shown));
    final hold = server.holdWrites = Completer<void>();

    await tester.tap(privateSwitch);
    await pumpFrames(tester);
    await tester.tap(find.text('Make private'));
    await _putArrived(tester, server);
    final readsBefore = _reads(server);
    shown.value = false;
    await pumpFrames(tester);
    hold.complete();
    await _refetched(tester, server, after: readsBefore);

    expect(tester.takeException(), isNull);
  });
}
