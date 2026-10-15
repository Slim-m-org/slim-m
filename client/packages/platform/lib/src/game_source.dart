// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What game this device is running, for rich presence (decision 0044).
///
/// Only programs on [gameAllowlist], or the game Steam itself says it is
/// running, are ever reported, and only while the person has switched game
/// detection on. A source that nobody listens to
/// reads nothing, and the process list is matched and thrown away, never
/// stored or logged.
library;

import 'game_allowlist.dart';
import 'game_source_stub.dart' if (dart.library.io) 'game_source_io.dart'
    as impl;
import 'polled_stream.dart';

/// A game from the allowlist that is running right now.
class RunningGame {
  const RunningGame(this.name);

  final String name;

  @override
  bool operator ==(Object other) => other is RunningGame && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// Emits null when no allowlisted game runs, and only on change.
abstract interface class GameSource {
  Stream<RunningGame?> watch();
}

/// The two things a host can tell us; both are read fresh on every poll.
abstract interface class GameProbe {
  /// Executable names of everything running. The caller only matches them.
  Future<Iterable<String>> runningProcessNames();

  /// The Steam app id Steam itself says is running, or null.
  Future<int?> runningSteamAppId();

  /// The name Steam's own install manifest gives [appId], or null.
  Future<String?> steamAppName(int appId);
}

/// Steam's own runtimes and redistributables run as apps too; they are never
/// what a person is playing.
bool isSteamTool(String name) {
  final lower = name.toLowerCase();
  return lower.startsWith('proton') ||
      lower.startsWith('steam linux runtime') ||
      lower.startsWith('steamworks') ||
      lower.contains('redistributable');
}

/// Linux truncates a process name to 15 characters, which would otherwise
/// hide any longer allowlisted name.
const _truncatedProcessName = 15;

String _normalise(String process) {
  final lower = process.trim().toLowerCase();
  return lower.endsWith('.exe') ? lower.substring(0, lower.length - 4) : lower;
}

bool _matchesProcess(AllowedGame game, String process) => game.processes.any(
      (name) =>
          name == process ||
          (process.length == _truncatedProcessName && name.startsWith(process)),
    );

/// The game that is running, or null. Steam's own answer wins over a
/// process match because it names the title exactly, the way other chat
/// apps name any Steam game; the allowlist covers games outside Steam.
RunningGame? pickRunningGame({
  required Iterable<String> processes,
  required int? steamAppId,
  String? steamAppName,
  List<AllowedGame> allowlist = gameAllowlist,
}) {
  if (steamAppId != null) {
    for (final game in allowlist) {
      if (game.steamAppId == steamAppId) return RunningGame(game.name);
    }
    final name = steamAppName?.trim();
    if (name != null && name.isNotEmpty && !isSteamTool(name)) {
      return RunningGame(name);
    }
  }
  final names = processes.map(_normalise).toSet();
  for (final game in allowlist) {
    if (names.any((name) => _matchesProcess(game, name))) {
      return RunningGame(game.name);
    }
  }
  return null;
}

const _defaultPollInterval = Duration(seconds: 15);

class AllowlistGameSource implements GameSource {
  AllowlistGameSource(
    this._probe, {
    Duration pollInterval = _defaultPollInterval,
    List<AllowedGame> allowlist = gameAllowlist,
  })  : _pollInterval = pollInterval,
        _allowlist = allowlist;

  final GameProbe _probe;
  final Duration _pollInterval;
  final List<AllowedGame> _allowlist;

  @override
  Stream<RunningGame?> watch() => polledStream<RunningGame>(
        interval: _pollInterval,
        read: () async {
          final steamAppId = await _probe.runningSteamAppId();
          return pickRunningGame(
            processes: await _probe.runningProcessNames(),
            steamAppId: steamAppId,
            steamAppName: steamAppId == null
                ? null
                : await _probe.steamAppName(steamAppId),
            allowlist: _allowlist,
          );
        },
      );
}

/// The source for this platform, or null when there is none. The platform is
/// a parameter so tests can take a branch their host is not.
GameSource? createGameSource({bool? linux, bool? windows, bool? macos}) =>
    impl.createGameSource(linux: linux, windows: windows, macos: macos);
