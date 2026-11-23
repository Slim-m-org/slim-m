// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Notices that the web image was redeployed under an open tab (decision
/// 0025, "Web client").
///
/// The bundle bakes its own build id in with `--dart-define=SLIMM_WEB_BUILD`
/// and the image serves the same id in `version.json`. A poll that reads a
/// different id means a newer bundle is live; `web_update_pill.dart` says so.
/// Nothing here ever reloads the page: that is the user's tap, so a message
/// half-typed is never lost to a deploy.
///
/// Whether this runs is a capability of the build, not a layout branch: it
/// needs a web build that was given an id, and nothing else.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'web_page.dart';

const _runningBuild = String.fromEnvironment('SLIMM_WEB_BUILD');

const webUpdateWatchInterval = Duration(minutes: 5);

typedef WebBuildFetcher = Future<String?> Function();

/// The id this bundle was built with; empty for a dev or test build.
final runningWebBuildProvider = Provider<String>((ref) => _runningBuild);

/// Whether this build can ever learn of a redeploy.
final webUpdateSupportedProvider = Provider<bool>(
  (ref) => kIsWeb && ref.watch(runningWebBuildProvider).isNotEmpty,
);

final webBuildFetcherProvider = Provider<WebBuildFetcher>(
  (ref) => fetchLiveWebBuild,
);

/// The id `version.json` reported last, null until a poll succeeds.
final liveWebBuildProvider = StateProvider<String?>((ref) => null);

/// The live id the user dismissed the pill for; a newer deploy shows it again.
final dismissedWebBuildProvider = StateProvider<String?>((ref) => null);

/// True while the shell's banner stack carries the notice, so the overlay pill stands down.
final webUpdateDockedProvider = StateProvider<bool>((ref) => false);

final webUpdateAvailableProvider = Provider<bool>((ref) {
  if (!ref.watch(webUpdateSupportedProvider)) return false;
  final live = ref.watch(liveWebBuildProvider);
  if (live == null || live == ref.watch(runningWebBuildProvider)) return false;
  return live != ref.watch(dismissedWebBuildProvider);
});

/// Polls on a timer and whenever the tab comes back to the foreground.
class WebUpdateWatcher with WidgetsBindingObserver {
  WebUpdateWatcher(this._ref, {this.interval = webUpdateWatchInterval});

  final Ref _ref;
  final Duration interval;
  Timer? _timer;

  void start() {
    if (_timer != null || !_ref.read(webUpdateSupportedProvider)) return;
    _timer = Timer.periodic(interval, (_) => unawaited(poll()));
    WidgetsBinding.instance.addObserver(this);
    unawaited(poll());
  }

  Future<void> poll() async {
    final live = await _ref.read(webBuildFetcherProvider)();
    if (live == null) return;
    _ref.read(liveWebBuildProvider.notifier).state = live;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(poll());
  }

  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

final webUpdateWatcherProvider = Provider.autoDispose<WebUpdateWatcher>((ref) {
  final watcher = WebUpdateWatcher(ref)..start();
  ref.onDispose(watcher.dispose);
  return watcher;
});
