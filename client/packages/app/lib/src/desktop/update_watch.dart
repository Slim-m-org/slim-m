// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The gap `update_check.dart`'s own doc names: that check only ever runs
/// during the splash, so someone who leaves slim-m open for days is never
/// told a newer build exists until they happen to quit and relaunch.
///
/// This re-runs the same best-effort, format-aware check on a repeating
/// timer for as long as the app stays open, and surfaces a find through
/// [inSessionUpdateProvider] rather than a prompt - [UpdateAvailableBanner]
/// (`update_available_banner.dart`) is the only thing that reads it.
///
/// Everything decision 0020/0025 already decided still applies: nothing is
/// downloaded or executed, a failure resolves to no update rather than an
/// error, and `SLIMM_NO_UPDATE_CHECK` (see [updateChecksDisabled]) still
/// switches this off entirely, the same as the splash.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart';

import '../providers/providers.dart';
import 'update_check.dart';

/// GitHub allows 60 unauthenticated requests per hour per source IP. Once
/// every six hours is four requests a day from this check - even an install
/// left running for months of uninterrupted uptime stays orders of magnitude
/// under a limit it would need to poll roughly 15x more often to ever risk.
const updateWatchInterval = Duration(hours: 6);

/// Whether this build should ever run the periodic check at all.
///
/// Desktop, plus Android, minus anything that opted out with
/// `SLIMM_NO_UPDATE_CHECK` - the same flag `startup_updates.dart` honours for
/// the splash's own one-shot check.
///
/// Android is here because it is the one platform with no update signal at
/// all. Desktop has this watcher and the splash; iOS has TestFlight; a
/// sideloaded apk has nothing, and there is no Play listing to give it one,
/// so without this a tester learns a new build exists only by thinking to
/// revisit the releases page. iOS is deliberately still absent: TestFlight
/// already nags, and a second prompt beside it would be noise.
bool updateWatchShouldRun() =>
    (isDesktopHost || isAndroidHost) && !updateChecksDisabled();

/// Runs [checkForClientUpdate] every [interval] for as long as something
/// keeps [updateWatcherProvider] alive, writing a find that has not already
/// been dismissed into [inSessionUpdateProvider].
///
/// No immediate first check on construction, unlike [VoiceCallHeartbeat]'s
/// proof-of-life ping: the splash this same session just passed through
/// already made one, and firing a second immediately after would only spend
/// part of the rate-limit budget above for no new information.
class UpdateWatcher {
  UpdateWatcher(
    this._ref, {
    this.interval = updateWatchInterval,
    CheckForClientUpdate check = checkForClientUpdate,
    InstallFormat? format,
    bool Function() shouldRun = updateWatchShouldRun,
  }) : _check = check,
       _format = format,
       _shouldRun = shouldRun;

  final Ref _ref;
  final Duration interval;
  final CheckForClientUpdate _check;
  final InstallFormat? _format;
  final bool Function() _shouldRun;
  Timer? _timer;

  /// Starts the timer, unless it is running already or [shouldRun] (a
  /// desktop host with the check not switched off) says this session should
  /// never poll at all.
  void start() {
    if (_timer != null || !_shouldRun()) return;
    _timer = Timer.periodic(interval, (_) => unawaited(_poll()));
  }

  void dispose() => _timer?.cancel();

  Future<void> _poll() async {
    try {
      final info = await _ref.read(appInfoProvider.future);
      final update = await _check(
        currentVersion: info.version,
        format: _format,
      );
      if (update == null) return;

      final prefs = await _ref.read(preferencesProvider.future);
      if (updateWasDismissed(
        dismissed: prefs.getString(dismissedUpdateVersionKey),
        candidate: update.version,
      )) {
        return;
      }
      _ref.read(inSessionUpdateProvider.notifier).state = update;
    } catch (_) {
      // Best-effort, same as the splash's own check: try again next tick.
    }
  }
}

/// The update this session knows about, or null.
///
/// Set by [UpdateWatcher]'s poll and by the manual check in Settings, and
/// deliberately *not* cleared when the banner is dismissed: the rail's gear
/// badge reads this, and the whole point of the badge is that it outlives the
/// banner. Dismissal is [dismissedBannerVersionProvider] plus the persisted
/// [dismissedUpdateVersionKey], which is what the splash's own "Not now"
/// writes, so either surface's dismissal holds for the other across launches.
final inSessionUpdateProvider = StateProvider<ClientUpdate?>((ref) => null);

/// The version whose banner has been dismissed in this session, or null.
///
/// Separate from [inSessionUpdateProvider] because "stop showing me the
/// banner" and "there is no update" are different facts, and the badge needs
/// the second one to stay true after the first.
final dismissedBannerVersionProvider = StateProvider<String?>((ref) => null);

/// Whether a known update is waiting, which is all the gear badge needs.
final updatePendingProvider = Provider<bool>(
  (ref) => ref.watch(inSessionUpdateProvider) != null,
);

/// Whether [UpdateAvailableBanner] actually has something to paint right
/// now: an update found and not yet dismissed.
///
/// Shared between that widget and [UpdateBannerHost] rather than each
/// re-deriving it, because the host uses the answer to decide whether to
/// reserve the banner's own status-bar inset at all - reserving it while
/// nothing is showing there left a permanent empty band above the rail on
/// every phone, banner or not.
final bannerVisibleProvider = Provider<bool>((ref) {
  final update = ref.watch(inSessionUpdateProvider);
  if (update == null) return false;
  return ref.watch(dismissedBannerVersionProvider) != update.version;
});

/// Forces [UpdateWatcher] into existence for as long as the desktop chrome
/// is mounted - `DesktopChrome` watches this, because a frameless shell
/// mounts no banner and the title bar chip still needs the periodic check.
/// Nothing here reads its own state; the timer it starts is the entire point.
final updateWatcherProvider = Provider.autoDispose<UpdateWatcher>((ref) {
  final watcher = UpdateWatcher(ref);
  watcher.start();
  ref.onDispose(watcher.dispose);
  return watcher;
});
