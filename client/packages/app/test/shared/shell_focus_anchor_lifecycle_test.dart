// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Alt-tab and a file picker park focus on the root scope; the shell anchor
/// must leave it there so Flutter restores the field, never behind a modal.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/shell_focus_anchor.dart';

class _Rig extends StatelessWidget {
  const _Rig({required this.composer, required this.dialogField});

  final FocusNode composer;
  final FocusNode dialogField;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ShellFocusAnchor(
        child: Builder(
          builder: (context) => Column(
            children: [
              SizedBox(width: 200, child: TextField(focusNode: composer)),
              TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => AlertDialog(
                    content: TextField(focusNode: dialogField, autofocus: true),
                  ),
                ),
                child: const Text('Open'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _switchAwayAndBack(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  await tester.pump();
  expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('shell'));
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pump();
}

/// FocusManager only parks focus on lifecycle changes on desktop and web.
final _desktop = TargetPlatformVariant.only(TargetPlatform.linux);

void main() {
  late FocusNode composer;
  late FocusNode dialogField;

  setUp(() {
    composer = FocusNode(debugLabel: 'composer');
    dialogField = FocusNode(debugLabel: 'dialog field');
  });

  tearDown(() {
    composer.dispose();
    dialogField.dispose();
  });

  Future<void> pumpRig(WidgetTester tester) async {
    // ignore: invalid_use_of_visible_for_testing_member
    FocusManager.instance.listenToApplicationLifecycleChangesIfSupported();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      ProviderScope(
        child: _Rig(composer: composer, dialogField: dialogField),
      ),
    );
    await tester.pump();
  }

  testWidgets('the composer has focus again after an alt-tab', (tester) async {
    await pumpRig(tester);
    composer.requestFocus();
    await tester.pump();

    await _switchAwayAndBack(tester);

    expect(composer.hasPrimaryFocus, isTrue);
  }, variant: _desktop);

  testWidgets('an open dialog keeps its field focused after an alt-tab', (
    tester,
  ) async {
    await pumpRig(tester);
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(dialogField.hasPrimaryFocus, isTrue);

    await _switchAwayAndBack(tester);

    expect(dialogField.hasPrimaryFocus, isTrue);
  }, variant: _desktop);

  testWidgets('focus that falls above an open dialog stays out of the shell', (
    tester,
  ) async {
    await pumpRig(tester);
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final dialogScope = dialogField.enclosingScope!;

    dialogScope.unfocus();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('shell'));
  }, variant: _desktop);
}
