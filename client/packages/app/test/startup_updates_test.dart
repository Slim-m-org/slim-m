// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The splash's update pass (decision 0025): ask once, and from then on
/// install a newer version during the mini splash when the answer was yes.
///
/// Every case drives the prompt the way a person does - by reading the
/// buttons off `startupPromptProvider` and calling one - because the pass
/// genuinely waits on that answer and a test that skipped it would prove
/// nothing about the waiting.
library;

import 'package:http/http.dart' as http;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/desktop/rpm_updater.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_failure.dart';
import 'package:slimm_app/src/desktop/startup_screen.dart';
import 'package:slimm_app/src/desktop/startup_state.dart';
import 'package:slimm_app/src/desktop/startup_updates.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ClientUpdate _update([InstallFormat format = InstallFormat.rpm]) =>
    ClientUpdate(
      version: '9.9.9',
      releaseUrl: 'https://example.invalid/release',
      format: format,
    );

/// A check that always finds [found], recording whether it ran at all.
class _Check {
  _Check(this.found);

  final ClientUpdate? found;
  var ran = false;

  Future<ClientUpdate?> call({
    required String currentVersion,
    http.Client? client,
    InstallFormat? format,
  }) async {
    ran = true;
    return found;
  }
}

/// A dnf that reports [ok] without touching the system.
class _Dnf implements RpmUpdater {
  _Dnf({this.ok = true, this.detail = ''});

  final bool ok;
  final String detail;
  var applied = false;
  String? lastCurrentVersion;

  @override
  Future<RpmUpdateResult> apply({String? currentVersion}) async {
    applied = true;
    lastCurrentVersion = currentVersion;
    return RpmUpdateResult(ok: ok, detail: detail);
  }

  @override
  Future<bool> repoEnabled() async => true;

  @override
  Future<String?> installedVersion() async => '1.0.0';
}

class _FakeSelfUpdate extends SelfUpdateController {
  _FakeSelfUpdate(super.ref, {this.onInstall, this.fail = false});

  final void Function(String currentVersion)? onInstall;
  final bool fail;

  @override
  Future<String?> install({
    required String currentVersion,
    InstallFormat? format,
    String? resolvedExecutable,
    String? os,
  }) async {
    onInstall?.call(currentVersion);
    if (fail) {
      ref
          .read(selfUpdateFailureProvider.notifier)
          .state = const SelfUpdateFailure(
        SelfUpdateFailureKind.downloadFailed,
        'could not download',
      );
      return null;
    }
    return '9.9.9';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer container({bool signedIn = true}) {
    final c = ProviderContainer(
      overrides: [
        preferencesProvider.overrideWith(
          (ref) => SharedPreferences.getInstance(),
        ),
        sessionProvider.overrideWithValue(
          api.SessionStore(tokens: signedIn ? _tokens : null),
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  /// Answers whatever the pass asks next, once it has asked. Returns the
  /// prompt it answered so a caller can assert on its wording.
  Future<StartupPrompt> answer(
    ProviderContainer c, {
    required bool primary,
  }) async {
    StartupPrompt? prompt;
    for (var i = 0; i < 200 && prompt == null; i++) {
      await Future<void>.delayed(Duration.zero);
      prompt = c.read(startupPromptProvider);
    }
    expect(prompt, isNotNull, reason: 'the splash never asked anything');
    final asked = prompt!;
    primary ? asked.onPrimary() : asked.onSecondary();
    return asked;
  }

  test('an install that has already said no is never asked again, and never '
      'even checks', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: false});
    final c = container();
    final check = _Check(_update());

    await runStartupUpdates(
      c,
      check: check.call,
      format: InstallFormat.rpm,
      currentVersion: '1.0.0',
    );

    expect(check.ran, isFalse);
    expect(c.read(startupPromptProvider), isNull);
  });

  test('a fresh install checks without asking, signed in or not', () async {
    for (final signedIn in [true, false]) {
      final c = container(signedIn: signedIn);
      final check = _Check(null);

      await runStartupUpdates(
        c,
        check: check.call,
        format: InstallFormat.rpm,
        currentVersion: '1.0.0',
      );

      expect(check.ran, isTrue, reason: 'on is the default');
      expect(c.read(startupPromptProvider), isNull);
      expect(
        (await SharedPreferences.getInstance()).containsKey(autoUpdateKey),
        isFalse,
        reason: 'the default is not an answer to save',
      );
    }
  });

  test(
    'a per-user tarball installs itself and relaunches without asking',
    () async {
      final c = container();
      var installedFor = '';
      var relaunched = false;
      final controllerOverride = selfUpdateProvider.overrideWith(
        (ref) => _FakeSelfUpdate(ref, onInstall: (v) => installedFor = v),
      );
      final scoped = ProviderContainer(
        parent: c,
        overrides: [controllerOverride],
      );
      addTearDown(scoped.dispose);

      await runStartupUpdates(
        scoped,
        check: _Check(_update(InstallFormat.tarball)).call,
        relaunch: () async => relaunched = true,
        format: InstallFormat.tarball,
        currentVersion: '1.0.0',
        selfApplies: true,
      );

      expect(installedFor, '1.0.0');
      expect(relaunched, isTrue);
      expect(scoped.read(startupStatusProvider), 'Restarting into 9.9.9');
    },
  );

  test('a failed per-user install keeps the current build and the failure '
      'in the persistent state', () async {
    final c = container();
    final scoped = ProviderContainer(
      parent: c,
      overrides: [
        selfUpdateProvider.overrideWith(
          (ref) => _FakeSelfUpdate(ref, fail: true),
        ),
      ],
    );
    addTearDown(scoped.dispose);

    await runStartupUpdates(
      scoped,
      check: _Check(_update(InstallFormat.tarball)).call,
      relaunch: () async => fail('nothing was installed to restart into'),
      format: InstallFormat.tarball,
      currentVersion: '1.0.0',
      selfApplies: true,
    );

    expect(
      scoped.read(selfUpdateFailureProvider)?.kind,
      SelfUpdateFailureKind.downloadFailed,
    );
  });

  test('a dnf install relaunches into the new build without asking', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: true});
    final c = container();
    final dnf = _Dnf();
    var relaunched = false;
    final prompts = <StartupPrompt?>[];
    final sub = c.listen(startupPromptProvider, (_, next) => prompts.add(next));

    await runStartupUpdates(
      c,
      check: _Check(_update()).call,
      rpm: dnf,
      relaunch: () async => relaunched = true,
      format: InstallFormat.rpm,
      currentVersion: '1.0.0',
    );
    sub.close();

    expect(dnf.applied, isTrue);
    expect(
      dnf.lastCurrentVersion,
      '1.0.0',
      reason:
          'apply needs the running version to tell "already installed, '
          'just restart" apart from "genuinely nothing newer"',
    );
    expect(relaunched, isTrue);
    expect(
      prompts.whereType<StartupPrompt>(),
      isEmpty,
      reason: 'the splash must not stop on a question it answers itself',
    );
    expect(c.read(startupStatusProvider), 'Restarting into 9.9.9');
  });

  test('a dnf that fails falls back to offering the release, and does not '
      'pretend it installed anything', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: true});
    final c = container();

    final pass = runStartupUpdates(
      c,
      check: _Check(_update()).call,
      rpm: _Dnf(ok: false, detail: 'Error: Transaction failed'),
      relaunch: () async => fail('nothing was installed to restart into'),
      format: InstallFormat.rpm,
      currentVersion: '1.0.0',
    );
    final prompt = await answer(c, primary: false);
    await pass;

    expect(prompt.title, 'Version 9.9.9 is available');
    expect(prompt.primaryLabel, 'Check GitHub');
    expect(prompt.detail, contains('sudo dnf upgrade --refresh slim-m-client'));
    expect(
      c.read(debugLogProvider).any((e) => e.message.contains('dnf')),
      isTrue,
      reason: 'the failure has to be diagnosable afterwards',
    );
  });

  test('a format dnf cannot touch is offered, not installed', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: true});
    final c = container();
    final dnf = _Dnf();

    final pass = runStartupUpdates(
      c,
      check: _Check(_update(InstallFormat.flatpak)).call,
      rpm: dnf,
      relaunch: () async => fail('a flatpak is never installed from here'),
      format: InstallFormat.flatpak,
      currentVersion: '1.0.0',
    );
    final prompt = await answer(c, primary: false);
    await pass;

    expect(dnf.applied, isFalse);
    expect(prompt.detail, updateActionHint(InstallFormat.flatpak));
    expect(prompt.primaryLabel, 'Check GitHub');
  });

  test('nothing newer means nothing is shown at all', () async {
    SharedPreferences.setMockInitialValues({autoUpdateKey: true});
    final c = container();

    await runStartupUpdates(
      c,
      check: _Check(null).call,
      format: InstallFormat.rpm,
      currentVersion: '1.0.0',
    );

    expect(c.read(startupPromptProvider), isNull);
  });

  test('a version turned down is not offered again until something newer '
      'exists', () async {
    SharedPreferences.setMockInitialValues({
      autoUpdateKey: true,
      dismissedUpdateVersionKey: '9.9.9',
    });
    final c = container();

    await runStartupUpdates(
      c,
      check: _Check(_update(InstallFormat.tarball)).call,
      format: InstallFormat.tarball,
      currentVersion: '1.0.0',
    );

    expect(c.read(startupPromptProvider), isNull);
  });
}
