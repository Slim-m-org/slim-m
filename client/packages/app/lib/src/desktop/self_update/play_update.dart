// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Play's flexible in-app update for a copy Google Play installed: Play
/// downloads in the background while the app runs, then restarts it into the
/// new version when the user says so (decision 0025, phase 3).
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Where a Play update stands, which is all the banner and Settings show.
enum PlayUpdateStage { none, available, downloading, downloaded }

/// The Play Core calls this flow makes; a port so tests can fake Play.
abstract interface class PlayUpdatePort {
  Future<AppUpdateInfo> checkForUpdate();

  /// Completes once Play has the update downloaded, or the user declined.
  Future<AppUpdateResult> startFlexibleUpdate();

  /// Restarts into the downloaded update; Play never completes this future.
  Future<void> completeFlexibleUpdate();

  Stream<InstallStatus> get installStatus;
}

class InAppUpdatePort implements PlayUpdatePort {
  const InAppUpdatePort();

  @override
  Future<AppUpdateInfo> checkForUpdate() => InAppUpdate.checkForUpdate();

  @override
  Future<AppUpdateResult> startFlexibleUpdate() =>
      InAppUpdate.startFlexibleUpdate();

  @override
  Future<void> completeFlexibleUpdate() => InAppUpdate.completeFlexibleUpdate();

  @override
  Stream<InstallStatus> get installStatus => InAppUpdate.installUpdateListener;
}

/// The stage Play's own report puts this install in. Play keeps a download
/// going across app restarts, so a check can land mid-download or after it.
PlayUpdateStage playStageFor(AppUpdateInfo info) {
  switch (info.installStatus) {
    case InstallStatus.downloaded || InstallStatus.installing:
      return PlayUpdateStage.downloaded;
    case InstallStatus.pending || InstallStatus.downloading:
      return PlayUpdateStage.downloading;
    default:
      final offered =
          info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.flexibleUpdateAllowed;
      return offered ? PlayUpdateStage.available : PlayUpdateStage.none;
  }
}

/// The stage after Play reports [status] while this install was at [current].
PlayUpdateStage playStageAfter(InstallStatus status, PlayUpdateStage current) =>
    switch (status) {
      InstallStatus.downloaded ||
      InstallStatus.installing => PlayUpdateStage.downloaded,
      InstallStatus.pending ||
      InstallStatus.downloading => PlayUpdateStage.downloading,
      InstallStatus.failed ||
      InstallStatus.canceled => PlayUpdateStage.available,
      InstallStatus.installed => PlayUpdateStage.none,
      InstallStatus.unknown => current,
    };

class PlayUpdateController extends Notifier<PlayUpdateStage> {
  StreamSubscription<InstallStatus>? _statuses;
  bool _starting = false;

  PlayUpdatePort get _port => ref.read(playUpdatePortProvider);

  @override
  PlayUpdateStage build() {
    ref.onDispose(() => unawaited(_statuses?.cancel()));
    return PlayUpdateStage.none;
  }

  /// Asks Play what it has; a failure keeps the stage it had.
  Future<void> refresh() async {
    if (_starting) return;
    try {
      final stage = playStageFor(await _port.checkForUpdate());
      if (!_starting) state = stage;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not ask Google Play for an update',
        error,
        stack,
      );
    }
  }

  /// Starts Play's background download of an [PlayUpdateStage.available]
  /// update; a decline or a failure offers it again.
  Future<void> start() async {
    if (state != PlayUpdateStage.available || _starting) return;
    _starting = true;
    state = PlayUpdateStage.downloading;
    _statuses ??= _port.installStatus.listen(
      (status) => state = playStageAfter(status, state),
      onError: (Object error, StackTrace stack) => AppLog.swallowed(
        LogTag.platform,
        'Lost Google Play update progress',
        error,
        stack,
      ),
    );
    try {
      final result = await _port.startFlexibleUpdate();
      state = result == AppUpdateResult.success
          ? PlayUpdateStage.downloaded
          : PlayUpdateStage.available;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Google Play could not download the update',
        error,
        stack,
      );
      state = PlayUpdateStage.available;
    } finally {
      _starting = false;
    }
  }

  /// Hands a [PlayUpdateStage.downloaded] update to Play, which restarts the
  /// app into it.
  void restart() {
    if (state != PlayUpdateStage.downloaded) return;
    unawaited(
      _port.completeFlexibleUpdate().catchError(
        (Object error, StackTrace stack) => AppLog.swallowed(
          LogTag.platform,
          'Google Play could not install the update',
          error,
          stack,
        ),
      ),
    );
  }
}

final playUpdatePortProvider = Provider<PlayUpdatePort>(
  (ref) => const InAppUpdatePort(),
);

final playUpdateProvider =
    NotifierProvider<PlayUpdateController, PlayUpdateStage>(
      PlayUpdateController.new,
    );

/// The stage whose banner was dismissed this session, so a later stage (the
/// download finishing) shows it again.
final dismissedPlayStageProvider = StateProvider<PlayUpdateStage?>(
  (ref) => null,
);

final playBannerVisibleProvider = Provider<bool>((ref) {
  final stage = ref.watch(playUpdateProvider);
  return stage != PlayUpdateStage.none &&
      ref.watch(dismissedPlayStageProvider) != stage;
});

/// The button label for [stage], or null when there is nothing to press.
String? playUpdateActionLabel(PlayUpdateStage stage) => switch (stage) {
  PlayUpdateStage.available => 'Update',
  PlayUpdateStage.downloading => 'Downloading...',
  PlayUpdateStage.downloaded => 'Restart',
  PlayUpdateStage.none => null,
};

/// Runs the action [stage]'s button names; downloading has none.
void runPlayUpdateAction(
  PlayUpdateController controller,
  PlayUpdateStage stage,
) {
  switch (stage) {
    case PlayUpdateStage.available:
      unawaited(controller.start());
    case PlayUpdateStage.downloaded:
      controller.restart();
    case PlayUpdateStage.downloading || PlayUpdateStage.none:
      break;
  }
}
