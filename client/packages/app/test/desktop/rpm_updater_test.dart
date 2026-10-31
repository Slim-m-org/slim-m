// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dnf path decision 0025 gives an rpm install: check the COPR repo is
/// there, enable it if it is not, then upgrade - every privileged step
/// through `pkexec`, so the system's own prompt is the consent.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/rpm_updater.dart';

/// One scripted `Process.run`, recording what it was asked to do.
class _Runner {
  _Runner(this.responses);

  final Map<String, ProcessResult> responses;
  final calls = <List<String>>[];

  /// Answers `rpm -q`, so a test can say what the upgrade actually did.
  ProcessResult Function()? versions;

  Future<ProcessResult> call(String executable, List<String> arguments) async {
    calls.add([executable, ...arguments]);
    if (executable == 'rpm') return versions?.call() ?? _ok('0.74.0');
    final key = [executable, ...arguments].join(' ');
    for (final entry in responses.entries) {
      if (key.contains(entry.key)) return entry.value;
    }
    return ProcessResult(0, 0, '', '');
  }
}

ProcessResult _ok([String out = '']) => ProcessResult(0, 0, out, '');
ProcessResult _fail(String err) => ProcessResult(0, 1, '', err);

/// The `pkexec dnf upgrade` call [runner] made, or null if it never did.
List<String>? _upgradeCall(_Runner runner) {
  for (final call in runner.calls) {
    if (call.first == 'pkexec' && call.contains('upgrade')) return call;
  }
  return null;
}

/// An updater that behaves as on an install without the rpm's helper.
RpmUpdater _updater(_Runner runner, {bool helper = false}) =>
    RpmUpdater(run: runner.call, helperInstalled: () => helper);

/// A runner whose repo is enabled and whose `rpm -q` walks from [before] to
/// [after] across the upgrade, which is how a real install proves it moved.
_Runner _upgrading({String before = '0.74.0', String after = '0.75.0'}) {
  var asked = 0;
  final runner = _Runner({'repolist': _ok(coprRepoId)});
  runner.versions = () => _ok(asked++ == 0 ? before : after);
  return runner;
}

void main() {
  group('repoListed', () {
    test('matches the repo id, not the description column', () {
      expect(
        repoListed(
          'repo id                    repo name\n'
          '$coprRepoId    Copr repo for slim-m\n'
          'fedora                     Fedora 44',
        ),
        isTrue,
      );
    });

    test('the repo the rpm itself ships counts too', () {
      expect(
        repoListed(
          'repo id   repo name\n'
          '$packagedRepoId    slim-m desktop client (COPR nc1107/slim-m)\n'
          'fedora    Fedora 44',
        ),
        isTrue,
        reason:
            'an rpm installed from a release download arrives with this '
            'one, and must not be asked to enable a repo it already has',
      );
    });

    test('an enabled list without it is not a match', () {
      expect(repoListed('fedora  Fedora 44\nupdates  Updates'), isFalse);
    });

    test('a repo whose id merely starts the same is not a match', () {
      expect(
        repoListed('repo id   repo name\nslim-m-nightly   Somebody else'),
        isFalse,
        reason: 'matching on a prefix would call an unrelated repo ours',
      );
    });
  });

  group('lastLines', () {
    test('keeps the tail and drops the blank lines between', () {
      expect(lastLines('one\n\ntwo\nthree\nfour\n'), 'two\nthree\nfour');
    });

    test('shorter output survives whole', () {
      expect(lastLines('only this'), 'only this');
    });
  });

  group('apply', () {
    test('upgrades straight away when the repo is already enabled', () async {
      final runner = _upgrading();
      final result = await _updater(runner).apply();

      expect(result.ok, isTrue);
      expect(
        runner.calls.any((c) => c.join(' ').contains('copr enable')),
        isFalse,
        reason: 'a repo already there must not be re-enabled',
      );
      expect(_upgradeCall(runner), [
        'pkexec',
        'dnf',
        'upgrade',
        '--refresh',
        '-y',
        rpmPackage,
      ]);
    });

    test(
      'runs the packaged helper, with no arguments, when it is there',
      () async {
        final runner = _upgrading();
        final result = await _updater(runner, helper: true).apply();

        expect(result.ok, isTrue);
        expect(runner.calls.where((c) => c.first == 'pkexec'), [
          ['pkexec', rpmUpdateHelper],
        ]);
      },
    );

    test('enables the repo first when it is missing', () async {
      var asked = 0;
      final runner = _Runner({'repolist': _ok('fedora  Fedora 44')});
      runner.versions = () => _ok(asked++ == 0 ? '0.74.0' : '0.75.0');
      final result = await _updater(runner).apply();

      expect(result.ok, isTrue);
      expect(runner.calls[1], [
        'pkexec',
        'dnf',
        'copr',
        'enable',
        '-y',
        coprProject,
      ]);
      expect(_upgradeCall(runner), isNotNull);
    });

    test('a refused prompt stops before the upgrade, and says why', () async {
      final runner = _Runner({
        'repolist': _ok('fedora  Fedora 44'),
        'copr enable': _fail('Error executing command as another user'),
      });
      final result = await _updater(runner).apply();

      expect(result.ok, isFalse);
      expect(result.detail, contains('another user'));
      expect(
        runner.calls.any((c) => c.contains('upgrade')),
        isFalse,
        reason: 'no point upgrading from a repo that is not there',
      );
    });

    test('a failed upgrade reports dnf\'s own last words', () async {
      final runner = _upgrading();
      runner.responses['upgrade'] = _fail(
        'Error: Transaction failed\nNothing to do',
      );
      final result = await _updater(runner).apply();

      expect(result.ok, isFalse);
      expect(result.detail, contains('Transaction failed'));
    });

    test('an exit 0 that installed nothing is not an update', () async {
      // The ordinary race: GitHub has the tag before COPR has the rpm, and `dnf upgrade -y` exits 0 having done nothing.
      final runner = _upgrading(before: '0.74.0', after: '0.74.0');
      final result = await _updater(runner).apply();

      expect(result.ok, isFalse);
      expect(result.detail, contains('still be building'));
    });

    test(
      'still genuinely stuck when currentVersion is passed and matches too',
      () async {
        // Naming the running version must not turn a real "still building" into success.
        final runner = _upgrading(before: '0.74.0', after: '0.74.0');
        final result = await _updater(runner).apply(currentVersion: '0.74.0');

        expect(result.ok, isFalse);
        expect(result.detail, contains('still be building'));
      },
    );

    test('nothing newer than what is already installed is success, not the '
        '"still building" failure - an earlier attempt already landed it and '
        'only a restart is left', () async {
      // The owner's own box: rpm -q says 0.83.0, but the process never restarted into it.
      final runner = _upgrading(before: '0.83.0', after: '0.83.0');
      final result = await _updater(runner).apply(currentVersion: '0.82.0');

      expect(result.ok, isTrue);
      expect(
        result.detail,
        isNot(contains('still be building')),
        reason: 'the reverse wording only belongs on a genuinely stuck install',
      );
    });

    test('the upgrade always refreshes the metadata first', () async {
      final runner = _upgrading();
      await _updater(runner).apply();

      // Measured on a real box: a cache written before the build was published hides it outright.
      expect(
        _upgradeCall(runner)!.contains('--refresh'),
        isTrue,
        reason: 'stale metadata hides a published build completely',
      );
    });

    test('no dnf on this box is a failure, not a crash', () async {
      Future<ProcessResult> missing(String e, List<String> a) =>
          throw const ProcessException('dnf', [], 'No such file');
      final result = await RpmUpdater(
        run: missing,
        helperInstalled: () => false,
      ).apply();

      expect(result.ok, isFalse);
    });
  });
}
