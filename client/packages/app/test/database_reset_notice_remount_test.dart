// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/database_key_store.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

Future<ProviderContainer> _pump(WidgetTester tester) async {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(body: DatabaseResetNotice(child: _Shell())),
      ),
    ),
  );
  return container;
}

class _Shell extends StatefulWidget {
  const _Shell();
  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(controller: controller);
}

void main() {
  testWidgets('shell state survives the notice appearing and being dismissed', (
    tester,
  ) async {
    final container = await _pump(tester);
    await tester.enterText(find.byType(TextField), 'unsent draft');
    final stateBefore = tester.state(find.byType(_Shell));

    container.read(databaseResetProvider.notifier).state =
        DatabaseResetReason.keyMissing;
    await tester.pump();
    expect(find.textContaining('lost the key'), findsOneWidget);
    expect(
      identical(tester.state(find.byType(_Shell)), stateBefore),
      isTrue,
      reason: 'showing the notice remounted the shell',
    );
    expect(find.text('unsent draft'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(
      identical(tester.state(find.byType(_Shell)), stateBefore),
      isTrue,
      reason: 'dismissing the notice remounted the shell',
    );
    expect(find.text('unsent draft'), findsOneWidget);
  });
}
