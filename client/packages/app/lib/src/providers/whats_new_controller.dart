// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether this install has anything new to be told about, and what.
///
/// Three constraints shape this, each chosen over an easier alternative:
///
/// - **Once per version, not every launch.** The last version a person was
///   shown something is persisted ([lastSeenWhatsNewVersionKey]), so a
///   relaunch on the same build reads as nothing pending rather than
///   replaying the same sheet. An in-memory "already shown this run" flag
///   was rejected: it would still show the sheet on every cold start, which
///   is not what "once per version" means.
/// - **Never on a fresh install.** [isFreshInstallProvider] is the same fact
///   [restoreSession] already computes for the keychain-wipe check, reused
///   rather than re-derived: a fresh install (or a wipe indistinguishable
///   from one) records the current version as already seen and shows
///   nothing, so a new user's first screen is never a changelog for updates
///   that happened before they existed.
///   A new account on an already-launched device gets the same treatment
///   through [justRegisteredProvider].
/// - **Never a gate.** [WhatsNewController] only ever decides what to show;
///   nothing reads its state to decide whether the app itself may proceed,
///   and the sheet it feeds is always dismissible.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../whats_new/whats_new_content.dart';
import 'providers.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// The `SharedPreferences` key the last version a what's-new sheet was shown
/// for is stored under. Global rather than per-account, the same reasoning
/// [themeChoiceKey] already carries: the build installed is a property of
/// the device, not of who happens to be signed into it.
const lastSeenWhatsNewVersionKey = 'slimm.whats_new.last_seen_version';

/// Every real build before backlog item 56's release-please fix reported
/// this exact, frozen [PackageInfo] version, so this is what every fresh
/// install recorded here - never a genuine version its owner was ever
/// actually on. Distinct from `null`, which already means "predates this
/// feature entirely" and must keep showing the backlog; see [_check].
const _neverTrackedVersion = '0.1.0';

/// True from the moment this app registers an account until the controller has
/// looked at it. A brand-new account has no history to catch up on, even on a
/// device that has launched before and so is not a [isFreshInstallProvider].
final justRegisteredProvider = StateProvider<bool>((ref) => false);

/// The entries, if any, still owed to whoever is using this install. Starts
/// empty and either stays that way or is populated once the async check in
/// the constructor resolves.
class WhatsNewController extends StateNotifier<List<WhatsNewEntry>> {
  WhatsNewController(this._ref) : super(const []) {
    unawaited(_check());
  }

  final Ref _ref;

  Future<void> _check() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final version = (await PackageInfo.fromPlatform()).version;

      if (_ref.read(isFreshInstallProvider) ||
          _ref.read(justRegisteredProvider)) {
        await prefs.setString(lastSeenWhatsNewVersionKey, version);
        return;
      }

      final lastSeen = prefs.getString(lastSeenWhatsNewVersionKey);
      // Re-baseline silently, the same as a fresh install; see the constant's own doc.
      if (lastSeen == _neverTrackedVersion) {
        await prefs.setString(lastSeenWhatsNewVersionKey, version);
        return;
      }
      final pending = pendingWhatsNewEntries(
        lastSeen: lastSeen,
        currentVersion: version,
      );
      if (!mounted || pending.isEmpty) return;
      state = pending;
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Never the reason a launch fails to reach the shell; stay silent',
        error,
        stack,
      );
    }
  }

  /// Called once the sheet built from [state] has been shown and dismissed.
  ///
  /// Marking seen here, rather than the moment [_check] decides there is
  /// something to show, means a process killed before the sheet ever painted
  /// tries again on the next launch instead of silently losing the notice.
  Future<void> markSeen() async {
    if (state.isEmpty) return;
    final version = (await PackageInfo.fromPlatform()).version;
    state = const [];
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      await prefs.setString(lastSeenWhatsNewVersionKey, version);
    } catch (error, stack) {
      AppLog.swallowed(
        LogTag.ui,
        'Best effort: worst case the same entries are shown again next launch',
        error,
        stack,
      );
    }
  }
}

/// Deliberately not `autoDispose`: the gate that reads this may rebuild
/// several times while signed in, and tearing this down between reads would
/// restart the async check and risk showing the sheet twice in one launch.
final whatsNewControllerProvider =
    StateNotifierProvider<WhatsNewController, List<WhatsNewEntry>>(
      (ref) => WhatsNewController(ref),
    );
