// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash on a bare Windows copy: it asks before moving the app, and then
/// moves it, installs from the layout and relaunches in one pass.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_app/src/desktop/startup_state.dart';
import 'package:slimm_app/src/desktop/startup_updates.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _update = ClientUpdate(
  version: '9.9.9',
  releaseUrl: 'https://example.invalid/release',
  format: InstallFormat.tarball,
);

Future<ClientUpdate?> _check({
  required String currentVersion,
  http.Client? client,
  InstallFormat? format,
}) async => _update;

class _FakeAdopt extends SelfUpdateController {
  _FakeAdopt(super.ref, {this.fail = false});

  final bool fail;
  String? adoptedFrom;
  String? releaseUrl;

  @override
  Future<String?> adoptAndInstall({
    required String currentVersion,
    required String releaseUrl,
    String? executable,
    Directory? root,
  }) async {
    adoptedFrom = currentVersion;
    this.releaseUrl = releaseUrl;
    if (fail) {
      ref.read(selfUpdateFailureProvider.notifier).state = SelfUpdateFailure(
        SelfUpdateFailureKind.installFailed,
        'could not move',
        releaseUrl: releaseUrl,
      );
      return null;
    }
    return '9.9.9';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> run(
    ProviderContainer c, {
    required bool accept,
    required Future<void> Function() relaunch,
  }) async {
    final pass = runStartupUpdates(
      c,
      StartupUpdateDeps(
        check: _check,
        relaunch: relaunch,
        format: InstallFormat.tarball,
        currentVersion: '1.0.0',
        selfApplies: false,
        adoptable: true,
      ),
    );
    StartupPrompt? prompt;
    for (var i = 0; i < 200 && prompt == null; i++) {
      await Future<void>.delayed(Duration.zero);
      prompt = c.read(startupPromptProvider);
    }
    expect(prompt?.primaryLabel, 'Move and update');
    expect(prompt?.detail, contains('moves into your account'));
    accept ? prompt!.onPrimary() : prompt!.onSecondary();
    await pass;
  }

  ProviderContainer containerWith({bool fail = false}) {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        selfUpdateProvider.overrideWith((ref) => _FakeAdopt(ref, fail: fail)),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('accepting moves the copy, installs and relaunches', () async {
    final c = containerWith();
    var relaunched = false;

    await run(c, accept: true, relaunch: () async => relaunched = true);

    final adopt = c.read(selfUpdateProvider) as _FakeAdopt;
    expect(adopt.adoptedFrom, '1.0.0');
    expect(relaunched, isTrue);
    expect(c.read(startupStatusProvider), 'Restarting into 9.9.9');
  });

  test('declining leaves the copy alone and is remembered', () async {
    final c = containerWith();

    await run(
      c,
      accept: false,
      relaunch: () async => fail('nothing was installed'),
    );

    expect((c.read(selfUpdateProvider) as _FakeAdopt).adoptedFrom, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(dismissedUpdateVersionKey), '9.9.9');
  });

  test(
    'a failure starts the current copy with the release page offered',
    () async {
      final c = containerWith(fail: true);

      await run(c, accept: true, relaunch: () async => fail('no restart'));

      final failure = c.read(selfUpdateFailureProvider);
      expect(failure?.kind, SelfUpdateFailureKind.installFailed);
      expect(failure?.releaseUrl, _update.releaseUrl);
    },
  );
}
