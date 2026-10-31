// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A region unmounted while its menu is open still tells its parent it closed,
/// or anything that pinned itself open for the menu stays pinned for good.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/context_menu_region.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('unmounting an open region reports it closed', (tester) async {
    final key = GlobalKey<ContextMenuRegionState>();
    final told = <bool>[];
    Widget host(bool mounted) => MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: mounted
            ? ContextMenuRegion(
                key: key,
                ownsFocusNode: false,
                onOpenChanged: told.add,
                itemsBuilder: (_, close) => [
                  AppMenuItem(label: 'One', onTap: close),
                ],
                child: const SizedBox(width: 100, height: 40),
              )
            : const SizedBox(),
      ),
    );
    await tester.pumpWidget(host(true));
    key.currentState!.open();
    await tester.pumpAndSettle();
    expect(told, [true]);

    await tester.pumpWidget(host(false));
    await tester.pump();

    expect(told, [true, false]);
  });

  testWidgets('a region closed in the ordinary way reports it once', (
    tester,
  ) async {
    final key = GlobalKey<ContextMenuRegionState>();
    final told = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: ContextMenuRegion(
            key: key,
            ownsFocusNode: false,
            onOpenChanged: told.add,
            itemsBuilder: (_, close) => [
              AppMenuItem(label: 'One', onTap: close),
            ],
            child: const SizedBox(width: 100, height: 40),
          ),
        ),
      ),
    );
    key.currentState!.open();
    await tester.pumpAndSettle();
    await tester.tap(find.text('One'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await tester.pump();

    expect(told, [true, false]);
  });
}
