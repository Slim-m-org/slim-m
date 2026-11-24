// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one screen in this app that stops a working session: the server this
/// client is signed in to will not serve this build any more (decision
/// 0025).
///
/// Fail-open by construction. Only a floor that was actually read, and
/// actually higher than this build, blocks anything; a pending request, an
/// unreachable server, a version that will not parse and a server too old to
/// declare a floor at all every render the app untouched. Refusing to run
/// because a check did not answer would turn a flaky network into an
/// unusable app, which is worse than the problem the floor exists for.
library;

import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../desktop/relaunch.dart';
import '../../../desktop/rpm_updater.dart';
import '../../../desktop/self_update/android_apk_update.dart';
import '../../../desktop/self_update/play_install.dart';
import '../../../desktop/self_update/play_update.dart';
import '../../../desktop/self_update/self_update_controller.dart';
import '../../../desktop/self_update/self_update_failure.dart';
import '../../../desktop/update_package_view.dart' show packageManagerCommand;
import '../../accounts/providers/account_providers.dart';
import '../providers/client_floor.dart';
import 'client_too_old_actions.dart';
import '../../../providers/providers.dart';
import '../../../web_update/web_page.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag, reportFailure;

export 'client_too_old_actions.dart' show releasesUrl;

/// Renders [child] unless this client is below the server's floor.
class ClientTooOldGate extends ConsumerWidget {
  const ClientTooOldGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floor = ref.watch(clientFloorProvider).valueOrNull;
    if (floor != ClientFloor.tooOld) return child;
    return const ClientTooOldScreen();
  }
}

class ClientTooOldScreen extends ConsumerStatefulWidget {
  const ClientTooOldScreen({
    super.key,
    this.format,
    this.rpm,
    this.isWeb = kIsWeb,
    this.onReload,
    this.relaunch,
    this.canRelaunch,
    this.fromPlay,
    this.fromAppStore,
  });

  /// Injectable for tests; the real build reads its own install format.
  final InstallFormat? format;
  final RpmUpdater? rpm;

  /// Injectable because `kIsWeb` is a constant no test can flip.
  final bool isWeb;
  final VoidCallback? onReload;

  /// Injectable; the real one starts a fresh copy and exits this one.
  final Future<void> Function()? relaunch;
  final bool? canRelaunch;

  /// Injectable; the real build asks the installer package it came from.
  final bool? fromPlay;
  final bool? fromAppStore;

  @override
  ConsumerState<ClientTooOldScreen> createState() => _ClientTooOldScreenState();
}

class _ClientTooOldScreenState extends ConsumerState<ClientTooOldScreen> {
  bool _busy = false;
  String? _error;
  String? _errorDetail;
  bool _installed = false;

  /// A phone only ever updates through its store, whatever a caller passes.
  InstallFormat get _format {
    if (isIOSHost) return InstallFormat.testFlight;
    if (isAndroidHost) return InstallFormat.apk;
    return widget.format ?? currentInstallFormat();
  }

  bool get _canRelaunch => widget.canRelaunch ?? canRelaunchThisProcess();

  Future<void> _restart() async {
    final relaunch =
        widget.relaunch ??
        () async {
          await spawnRelaunch();
          exit(0);
        };
    await relaunch();
  }

  Future<bool> _launch(String url, String what) async {
    try {
      return await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
    } on PlatformException catch (error, stack) {
      AppLog.swallowed(LogTag.auth, 'Could not open $what', error, stack);
      return false;
    }
  }

  Future<void> _open(String url, String what, {String? fallback}) async {
    var opened = await _launch(url, what);
    if (!opened && fallback != null) opened = await _launch(fallback, what);
    if (!mounted || opened) return;
    setState(() => _error = 'Could not open $what.');
  }

  Future<void> _openRelease() => _open(releasesUrl, 'the release page');

  TooOldAction get _action {
    final info = ref.watch(appInfoProvider).valueOrNull;
    return tooOldActionFor(
      isWeb: widget.isWeb,
      format: _format,
      fromPlay: widget.fromPlay ?? (info != null && installedFromPlay(info)),
      fromAppStore:
          widget.fromAppStore ?? (info != null && installedFromAppStore(info)),
      selfApplies: ref.watch(selfApplyAvailableProvider),
    );
  }

  Future<void> _update(TooOldAction action) async {
    switch (action) {
      case TooOldAction.reload:
        (widget.onReload ?? reloadPage)();
      case TooOldAction.release:
        await _openRelease();
      case TooOldAction.testFlight:
        await _open('itms-beta://', 'TestFlight');
      case TooOldAction.appStore:
        await _open(appStoreUrl, 'the App Store');
      case TooOldAction.none:
        break;
      case TooOldAction.play:
        await _updateFromPlay();
      case TooOldAction.dnf:
        await _guarded(_updateWithDnf);
      case TooOldAction.apk:
        await _guarded(_updateApk);
      case TooOldAction.selfUpdate:
        await _guarded(_selfUpdate);
    }
  }

  Future<void> _guarded(Future<void> Function() step) async {
    setState(() {
      _busy = true;
      _error = null;
      _errorDetail = null;
    });
    try {
      await step();
    } on SelfUpdateFailure catch (failure) {
      _fail(failure.message, failure.detail);
    } catch (error, stack) {
      reportFailure(
        LogTag.platform,
        'update from the too-old screen',
        error,
        stack,
      );
      _fail('The update did not finish.', null);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _fail(String line, String? detail) {
    if (!mounted) return;
    setState(() {
      _error = line;
      _errorDetail = detail;
    });
  }

  /// Play's own flow when it has an update, its listing when it does not.
  Future<void> _updateFromPlay() async {
    final controller = ref.read(playUpdateProvider.notifier);
    if (ref.read(playUpdateProvider) == PlayUpdateStage.none) {
      setState(() => _busy = true);
      await controller.refresh();
      if (mounted) setState(() => _busy = false);
    }
    final stage = ref.read(playUpdateProvider);
    if (stage == PlayUpdateStage.none) {
      await _open(playListingUrl, 'Google Play', fallback: playListingWebUrl);
      return;
    }
    runPlayUpdateAction(controller, stage);
  }

  Future<void> _updateApk() async {
    final info = await ref.read(appInfoProvider.future);
    final outcome = await ref.read(apkUpdateRunnerProvider)(info.version);
    if (outcome == null) {
      await _openRelease();
    } else if (outcome == ApkInstallOutcome.needsPermission) {
      _fail(
        'Allow installs from slim-m in Android settings, then try again.',
        null,
      );
    }
  }

  Future<void> _selfUpdate() async {
    final info = await ref.read(appInfoProvider.future);
    final version = await ref
        .read(selfUpdateProvider)
        .install(currentVersion: info.version);
    if (!mounted) return;
    if (version != null) {
      setState(() => _installed = true);
      return;
    }
    final failure = ref.read(selfUpdateFailureProvider);
    _fail(failure?.message ?? 'The update did not finish.', failure?.detail);
  }

  /// dnf can finish the job from here, which is the whole point of asking on
  /// this screen rather than only telling: an rpm user is one prompt away
  /// from a client that works again.
  Future<void> _updateWithDnf() async {
    final mine = ref.read(appInfoProvider).valueOrNull?.version;
    final result = await (widget.rpm ?? const RpmUpdater()).apply(
      currentVersion: mine,
    );
    if (!mounted) return;
    setState(() => _installed = result.ok);
    if (!result.ok) {
      _fail('The install did not finish.', _firstLine(result.detail));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final mine = ref.watch(appInfoProvider).valueOrNull?.version;
    final action = _action;
    final playStage = ref.watch(playUpdateProvider);
    final host = ref.watch(accountHostProvider);

    return Scaffold(
      backgroundColor: tokens.surfaceBase,
      body: LayoutBuilder(
        builder: (context, viewport) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: viewport.maxHeight),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.s24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        AppIcons.download,
                        size: AppSizes.icon32,
                        color: tokens.accent,
                      ),
                      const SizedBox(height: AppSpacing.s16),
                      Text(
                        'This version can no longer connect',
                        textAlign: TextAlign.center,
                        style: AppText.heading.copyWith(
                          color: tokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.s8),
                      Text(
                        mine == null
                            ? 'This Space has moved on to a newer version of '
                                  'slim-m. Update to carry on.'
                            : 'This Space has moved on to a newer version of '
                                  'slim-m. You are on $mine. Update to carry on.',
                        textAlign: TextAlign.center,
                        style: AppText.body.copyWith(
                          color: tokens.textSecondary,
                        ),
                      ),
                      if (_error == null) ...[
                        const SizedBox(height: AppSpacing.s8),
                        Text(
                          _installed
                              ? (_canRelaunch
                                    ? 'Installed. Restart slim-m to finish.'
                                    : 'Installed. Close and reopen slim-m to '
                                          'finish.')
                              : tooOldHint(action, _format),
                          textAlign: TextAlign.center,
                          style: AppText.caption.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ],
                      if (_error case final line?) ...[
                        const SizedBox(height: AppSpacing.s16),
                        _FailureNote(
                          line: line,
                          detail: _errorDetail,
                          command: action == TooOldAction.dnf
                              ? packageManagerCommand(_format)
                              : null,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.s24),
                      if (_installed && _canRelaunch)
                        AppButton(
                          label: 'Restart',
                          icon: AppIcons.retry,
                          variant: AppButtonVariant.primary,
                          size: AppButtonSize.lg,
                          full: true,
                          onPressed: _restart,
                        )
                      else if (!_installed && action != TooOldAction.none)
                        AppButton(
                          label: _label(
                            action,
                            playStage,
                            retry: _error != null,
                          ),
                          variant: AppButtonVariant.primary,
                          size: AppButtonSize.lg,
                          full: true,
                          busy:
                              _busy || playStage == PlayUpdateStage.downloading,
                          onPressed: () => _update(action),
                        ),
                      if (_error != null && _hasReleaseFallback(action)) ...[
                        const SizedBox(height: AppSpacing.s8),
                        AppButton(
                          label: 'Open the release page',
                          variant: AppButtonVariant.ghost,
                          full: true,
                          onPressed: _openRelease,
                        ),
                      ],
                      if (host != null) ...[
                        const SizedBox(height: AppSpacing.s24),
                        AppButton(
                          label: 'Use another Space',
                          icon: AppIcons.serverSwitcher,
                          variant: AppButtonVariant.secondary,
                          full: true,
                          onPressed: () => unawaited(useAnotherSpace(host)),
                        ),
                        const SizedBox(height: AppSpacing.s8),
                        AppButton(
                          label: 'Sign out of this Space',
                          icon: AppIcons.signOut,
                          variant: AppButtonVariant.ghost,
                          full: true,
                          onPressed: () => unawaited(signOutOfThisSpace(host)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _firstLine(String text) => text.trim().split('\n').first;

/// One calm line about what went wrong, the manual command, and nothing
/// stacked: the primary action above it is the retry.
class _FailureNote extends StatelessWidget {
  const _FailureNote({required this.line, this.detail, this.command});

  final String line;
  final String? detail;
  final String? command;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            line,
            textAlign: TextAlign.center,
            style: AppText.ui.copyWith(color: tokens.dangerText),
          ),
          if (detail case final detail? when detail.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(
              detail,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ],
          if (command case final command?) ...[
            const SizedBox(height: AppSpacing.s8),
            Text(
              'Or run it yourself:',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            SelectableText(
              command,
              textAlign: TextAlign.center,
              style: AppText.code.copyWith(color: tokens.textPrimary),
            ),
          ],
        ],
      ),
    );
  }
}

bool _hasReleaseFallback(TooOldAction action) => switch (action) {
  TooOldAction.dnf || TooOldAction.apk || TooOldAction.selfUpdate => true,
  _ => false,
};

String _label(
  TooOldAction action,
  PlayUpdateStage playStage, {
  required bool retry,
}) => switch (action) {
  TooOldAction.dnf => retry ? 'Try again' : 'Update now',
  TooOldAction.reload => 'Reload',
  TooOldAction.testFlight => 'Open TestFlight',
  TooOldAction.appStore => 'Open the App Store',
  TooOldAction.play when playStage == PlayUpdateStage.downloaded => 'Restart',
  TooOldAction.play => 'Update in Google Play',
  TooOldAction.apk ||
  TooOldAction.selfUpdate => retry ? 'Try again' : 'Update now',
  _ => 'Open the release',
};
