// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Applying a client update to an rpm install, through dnf.
///
/// Decision 0020 fixed the rule: an rpm is root-owned, so the app never
/// replaces its own files; it asks the package manager to. `pkexec` puts
/// the system's own polkit prompt in front of that, which is the consent
/// step - the app never escalates silently. The package comes from the COPR
/// repo `release.yml` publishes on every client release, so the first thing
/// checked is that the repo is enabled at all; without it dnf would report
/// "nothing to do" against a release page it cannot see.
library;

import 'dart:async';
import 'dart:io';

import 'update_check.dart' show isNewer;

/// How dnf is run, so a test can script exit codes and output.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<ProcessResult> _realRunner(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

/// The COPR project the rpm updates from.
const coprProject = 'nc1107/slim-m';

/// The repo id dnf lists once `dnf copr enable` has run.
const coprRepoId = 'copr:copr.fedorainfracloud.org:nc1107:slim-m';

/// The repo id of the file the rpm itself ships, in
/// `packaging/rpm/slim-m-client.repo`. Same COPR project, a different id on
/// purpose, so it can never contend with the file `dnf copr enable` writes for
/// [coprRepoId]; that file's own header has the reasoning. Either id being
/// enabled means dnf can see the package, which is all this checks for.
const packagedRepoId = 'slim-m';

const rpmPackage = 'slim-m-client';

/// One dnf step's outcome, kept as the last lines dnf printed so a failure
/// can be shown in the splash verbatim rather than as "update failed".
class RpmUpdateResult {
  const RpmUpdateResult({required this.ok, required this.detail});

  final bool ok;
  final String detail;
}

/// How long any one dnf or rpm step may take before the splash stops waiting.
///
/// Generous because an upgrade is legitimately slow and the polkit prompt is
/// the consent step, but finite: dnf waiting on another package manager's lock
/// would otherwise hold the app unstarted forever. The process itself is not
/// killed, since pkexec runs it as root and this user cannot signal it.
const rpmStepTimeout = Duration(minutes: 10);

class RpmUpdater {
  const RpmUpdater({
    ProcessRunner run = _realRunner,
    Duration stepTimeout = rpmStepTimeout,
  }) : _run = run,
       _stepTimeout = stepTimeout;

  final ProcessRunner _run;
  final Duration _stepTimeout;

  /// Whether the COPR repo is enabled, read from `dnf repolist --enabled`,
  /// which needs no privilege.
  Future<bool> repoEnabled() async {
    try {
      final result = await _run('dnf', [
        'repolist',
        '--enabled',
      ]).timeout(_stepTimeout);
      return result.exitCode == 0 && repoListed('${result.stdout}');
    } on ProcessException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// The version rpm currently has installed, or null when it cannot say.
  Future<String?> installedVersion() async {
    try {
      final result = await _run('rpm', [
        '-q',
        '--queryformat',
        '%{VERSION}',
        rpmPackage,
      ]).timeout(_stepTimeout);
      if (result.exitCode != 0) return null;
      final version = '${result.stdout}'.trim();
      return version.isEmpty ? null : version;
    } on ProcessException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  /// Enables the repo if needed, then upgrades the package. Each privileged
  /// step goes through `pkexec`, so the user sees the system's own prompt
  /// once per step; a refused prompt is a non-zero exit like any other.
  ///
  /// `--refresh` is not optional. dnf caches repository metadata, and a
  /// cache written before the new build was published hides it completely -
  /// measured on the owner's own box, where `check-upgrade` saw 0.73.0 while
  /// COPR had 0.75.0 built and waiting.
  ///
  /// Success is the installed version actually changing across this call, or
  /// having already changed before it - not dnf's exit code. Two different
  /// cases both leave dnf reporting "nothing to do" (`before == after`):
  ///
  /// - The COPR build genuinely has not finished publishing yet - GitHub has
  ///   the tag minutes before the rpm exists - and [currentVersion] is still
  ///   what is installed too. Reporting that as installed would offer a
  ///   restart into the very same build, so this is the one real failure.
  /// - An earlier attempt (this session or a previous one) already
  ///   installed the update, but the process was never restarted into it -
  ///   `rpm -q` and [currentVersion] disagree. There is nothing left to
  ///   download, only a restart, which is success, not the error it used to
  ///   report ("dnf had nothing newer... may still be building") on a
  ///   package that had, in fact, already arrived.
  ///
  /// [currentVersion] is the running build's own version
  /// ([appInfoProvider]/`PackageInfo`), not the version being offered: what
  /// matters is whether dnf has already gotten this install past what is
  /// actually running, regardless of which release triggered the check.
  Future<RpmUpdateResult> apply({String? currentVersion}) async {
    if (!await repoEnabled()) {
      final enabled = await _privileged([
        'dnf',
        'copr',
        'enable',
        '-y',
        coprProject,
      ]);
      if (!enabled.ok) return enabled;
    }

    final before = await installedVersion();
    final upgraded = await _privileged([
      'dnf',
      'upgrade',
      '--refresh',
      '-y',
      rpmPackage,
    ]);
    if (!upgraded.ok) return upgraded;

    final after = await installedVersion();
    if (before != null && after != null && before == after) {
      if (currentVersion != null && isNewer(after, currentVersion)) {
        return RpmUpdateResult(
          ok: true,
          detail: '$after is already installed; restart to use it.',
        );
      }
      return RpmUpdateResult(
        ok: false,
        detail:
            'dnf had nothing newer than $after to install; the package for '
            'this release may still be building.',
      );
    }
    return upgraded;
  }

  Future<RpmUpdateResult> _privileged(List<String> command) async {
    try {
      final result = await _run('pkexec', command).timeout(_stepTimeout);
      return RpmUpdateResult(
        ok: result.exitCode == 0,
        detail: lastLines('${result.stdout}\n${result.stderr}'),
      );
    } on ProcessException catch (e) {
      return RpmUpdateResult(ok: false, detail: e.message);
    } on TimeoutException {
      return RpmUpdateResult(
        ok: false,
        detail: 'dnf did not finish within ${_stepTimeout.inMinutes} minutes.',
      );
    }
  }
}

/// Whether [repolist] (dnf's `repolist --enabled` output) names the COPR
/// repo. Matched on the id, not the description column, which dnf5 renames.
bool repoListed(String repolist) => repolist
    .split('\n')
    .map((line) => line.trim())
    .any(
      (line) =>
          line.startsWith(coprRepoId) ||
          line == packagedRepoId ||
          line.startsWith('$packagedRepoId '),
    );

/// The last few non-empty lines of [output], for a failure detail line.
String lastLines(String output, {int count = 3}) {
  final lines = output
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.trim().isNotEmpty)
      .toList();
  return lines.skip(lines.length > count ? lines.length - count : 0).join('\n');
}
