// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A preference controller nobody restores comes up at its default on every
/// launch and only saves for the session, and nothing complains. The registry
/// is the one list bootstrap iterates, and this test fails when a controller
/// that restores itself is missing from it.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/startup_restores.dart';

/// Restored by `restoreSplashFloor`, which needs the floor it answers.
const _restoredSeparately = {'SplashDurationController'};

String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//.*'), '');

Set<String> _restoringControllers() {
  final found = <String>{};
  final restores = RegExp(
    r'Future<void> restore\(\)|extends (Enum|Bool)PreferenceController',
  );
  for (final file in Directory('lib/src/providers').listSync()) {
    if (file is! File || !file.path.endsWith('.dart')) continue;
    if (file.path.endsWith('preference_controller.dart')) continue;
    final parts = _withoutComments(
      file.readAsStringSync(),
    ).split(RegExp(r'(?=\bclass\s+\w+)'));
    for (final part in parts.skip(1)) {
      if (restores.hasMatch(part)) {
        found.add(RegExp(r'class\s+(\w+)').firstMatch(part)!.group(1)!);
      }
    }
  }
  return found;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('every controller that restores itself is in the startup registry', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final registered = {
      for (final build in restorablePreferences.values)
        build(container).runtimeType.toString(),
    };

    final forgotten = _restoringControllers()
        .difference(registered)
        .difference(_restoredSeparately);

    expect(forgotten, isEmpty, reason: 'never restored at startup');
    expect(registered, isNotEmpty);
  });

  test(
    'a stored enum name and a junk one both restore through the base',
    () async {
      SharedPreferences.setMockInitialValues({
        timeFormatPreferenceKey: 'h24',
        motionPreferenceKey: 'not-a-choice',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);

      for (final name in ['time format', 'motion']) {
        await restorablePreferences[name]!(container).restore();
      }

      expect(
        container.read(timeFormatControllerProvider),
        TimeFormatPreference.h24,
      );
      expect(container.read(motionPreferenceControllerProvider).name, 'system');
    },
  );
}
