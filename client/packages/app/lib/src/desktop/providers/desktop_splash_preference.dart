// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the desktop startup splash shows at all, and how long it holds the
/// screen when it does, as a user setting.
///
/// Both controllers restore and persist on every platform, the same as every
/// other performance preference - only `main.dart`'s bootstrap sequence,
/// itself a no-op off Linux/macOS/Windows, ever reads them to pick
/// [awaitBootstrapWithSplashFloor]'s own floor. [PerformanceSettingsSection]
/// hides both rows outside a desktop host, since neither does anything on a
/// phone or the web.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../splash_floor.dart' show minSplashDuration;
import '../../providers/providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The old separate on/off key, read once on restore to migrate an install
/// that had the splash turned off into [SplashDuration.disabled] - the
/// choice that replaced the toggle. Never written any more.
const desktopSplashEnabledKey = 'slimm.performance.desktop_splash_enabled';

/// A small set of named floors rather than a millisecond slider: nobody
/// thinks in milliseconds, and [minSplashDuration]'s own history (280ms, then
/// 560ms, then 900ms, each retuned against a real run) is exactly the kind of
/// value a slider invites a user to mistune with none of the owner's own
/// eyes-on feedback loop to catch it.
enum SplashDuration { disabled, brief, standard, long }

extension SplashDurationX on SplashDuration {
  /// The floor [awaitBootstrapWithSplashFloor] waits out when the splash is
  /// enabled. [standard] is [minSplashDuration] itself, not a second copy of
  /// 900ms, so the two can never drift apart.
  Duration get duration => switch (this) {
    // No splash: a zero floor still runs awaitBootstrapWithSplashFloor's concurrent-wait shape, so "off" needs no second code path.
    SplashDuration.disabled => Duration.zero,
    SplashDuration.brief => const Duration(milliseconds: 500),
    SplashDuration.standard => minSplashDuration,
    SplashDuration.long => const Duration(milliseconds: 1500),
  };

  String get label => switch (this) {
    SplashDuration.disabled => 'Disabled',
    SplashDuration.brief => 'Brief',
    SplashDuration.standard => 'Standard (default)',
    SplashDuration.long => 'Long',
  };
}

const desktopSplashDurationKey = 'slimm.performance.desktop_splash_duration';

const defaultSplashDuration = SplashDuration.standard;

class SplashDurationController extends StateNotifier<SplashDuration> {
  SplashDurationController(this._ref) : super(defaultSplashDuration);

  final Ref _ref;

  /// A missing or unrecognised stored value leaves the default alone, the
  /// same degrade the other named-choice preferences use.
  Future<void> restore() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final stored = prefs.getString(desktopSplashDurationKey);
      for (final value in SplashDuration.values) {
        if (value.name == stored) {
          state = value;
          return;
        }
      }
      // No duration stored: migrate an install whose old on/off toggle was off into the disabled choice; a never-set or on toggle keeps the default.
      if (prefs.getBool(desktopSplashEnabledKey) == false) {
        state = SplashDuration.disabled;
      }
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.platform,
        'Could not read the splash screen setting; using the standard one',
        error,
        stack,
      );
    }
  }

  Future<void> select(SplashDuration value) async {
    state = value;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(desktopSplashDurationKey, value.name);
  }
}

final splashDurationControllerProvider =
    StateNotifierProvider<SplashDurationController, SplashDuration>(
      SplashDurationController.new,
    );

/// The [Duration] [awaitBootstrapWithSplashFloor] needs for a chosen
/// splash setting - [SplashDuration.disabled] carries `Duration.zero`, so
/// "off" is just one of the choices rather than a separate flag. Kept as its
/// own pure function, not inline in `main.dart`'s private bootstrap helper,
/// so the mapping stays unit-testable: that bootstrap path is never
/// exercised in tests (decision 0012's "never raise a real window" rule).
Duration splashFloorFor(SplashDuration duration) => duration.duration;
