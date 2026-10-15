// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Game detection reports only allowlisted games, reads nothing until
/// someone listens, and prefers Steam's own answer (decision 0044).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/game_allowlist.dart';
import 'package:slimm_platform/src/game_source.dart';
import 'package:slimm_platform/src/game_source_io.dart' as io;

class _FakeProbe implements GameProbe {
  _FakeProbe(
      {this.processes = const [], this.steamAppId, this.steamNames = const {}});

  Iterable<String> processes;
  int? steamAppId;
  Map<int, String> steamNames;
  int reads = 0;

  @override
  Future<Iterable<String>> runningProcessNames() async {
    reads++;
    return processes;
  }

  @override
  Future<int?> runningSteamAppId() async => steamAppId;

  @override
  Future<String?> steamAppName(int appId) async => steamNames[appId];
}

void main() {
  group('pickRunningGame', () {
    test('an allowlisted process is reported by its friendly name', () {
      final game =
          pickRunningGame(processes: ['bash', 'cs2'], steamAppId: null);
      expect(game, const RunningGame('Counter-Strike 2'));
    });

    test('the windows spelling matches the same entry', () {
      final game = pickRunningGame(
        processes: ['Terraria.exe'],
        steamAppId: null,
      );
      expect(game?.name, 'Terraria');
    });

    test('a program not on the list is never reported', () {
      expect(
        pickRunningGame(
          processes: ['firefox', 'code', 'my-secret-game'],
          steamAppId: null,
        ),
        isNull,
      );
      expect(
          pickRunningGame(
              processes: ['cs2'], steamAppId: null, allowlist: const []),
          isNull);
    });

    test('a steam app id Steam cannot name is not reported', () {
      expect(pickRunningGame(processes: [], steamAppId: 999999999), isNull);
    });

    test('any steam game is named from Steam own manifest', () {
      expect(
        pickRunningGame(
            processes: [], steamAppId: 1145360, steamAppName: 'Hades'),
        const RunningGame('Hades'),
      );
    });

    test('steam runtimes and redistributables are never a game', () {
      for (final tool in [
        'Proton 9.0',
        'Steam Linux Runtime 3.0 (sniper)',
        'Steamworks Common Redistributables',
      ]) {
        expect(
            pickRunningGame(processes: [], steamAppId: 1, steamAppName: tool),
            isNull,
            reason: tool);
      }
    });

    test('steam wins over a process match and names the title', () {
      final game = pickRunningGame(processes: ['cs2'], steamAppId: 440);
      expect(game?.name, 'Team Fortress 2');
    });

    test('a 15 character linux comm still matches a longer name', () {
      const list = [
        AllowedGame('Long', processes: ['averylongprocessname']),
      ];
      expect(
        pickRunningGame(
          processes: ['averylongproces'],
          steamAppId: null,
          allowlist: list,
        ),
        const RunningGame('Long'),
      );
      expect(
        pickRunningGame(
          processes: ['averylong'],
          steamAppId: null,
          allowlist: list,
        ),
        isNull,
      );
    });

    test('every allowlist entry can be recognised somehow', () {
      for (final game in gameAllowlist) {
        expect(game.processes.isNotEmpty || game.steamAppId != null, isTrue);
        for (final name in game.processes) {
          expect(name, name.toLowerCase());
          expect(name.endsWith('.exe'), isFalse);
        }
      }
    });
  });

  group('AllowlistGameSource', () {
    test('reads nothing until someone listens', () async {
      final probe = _FakeProbe(processes: ['cs2']);
      final source = AllowlistGameSource(probe);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(probe.reads, 0);

      final first = await source.watch().first;
      expect(first?.name, 'Counter-Strike 2');
      expect(probe.reads, 1);
    });

    test('emits on change only, and null when the game quits', () async {
      final probe = _FakeProbe(processes: ['cs2']);
      final source = AllowlistGameSource(
        probe,
        pollInterval: const Duration(milliseconds: 10),
      );
      final seen = <RunningGame?>[];
      final sub = source.watch().listen(seen.add);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      probe.processes = ['bash'];
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await sub.cancel();
      expect(seen, [const RunningGame('Counter-Strike 2'), null]);
    });

    test('the steam app id alone is enough to name the game', () async {
      final source = AllowlistGameSource(_FakeProbe(steamAppId: 730));
      expect(await source.watch().first, const RunningGame('Counter-Strike 2'));
    });

    test('a steam game off the list is named through the probe', () async {
      final source = AllowlistGameSource(
        _FakeProbe(steamAppId: 1145360, steamNames: {1145360: 'Hades'}),
      );
      expect(await source.watch().first, const RunningGame('Hades'));
    });

    test('a probe that throws reads as no game', () async {
      final source = AllowlistGameSource(_ThrowingProbe());
      expect(await source.watch().first, isNull);
    });
  });

  group('host output parsing', () {
    test('steam library folders and app manifests', () {
      const folders = '''
"libraryfolders"
{
	"0"
	{
		"path"		"/home/npc/.local/share/Steam"
	}
	"1"
	{
		"path"		"D:\\\\SteamLibrary"
	}
}''';
      expect(io.parseSteamLibraryPaths(folders),
          ['/home/npc/.local/share/Steam', r'D:\SteamLibrary']);
      const acf = '''
"AppState"
{
	"appid"		"1145360"
	"name"		"Hades"
}''';
      expect(io.parseAppManifestName(acf), 'Hades');
      expect(io.parseAppManifestName('{}'), isNull);
    });

    test('steam vdf', () {
      const vdf = '''
"Registry"
{
	"HKCU"
	{
		"Software"
		{
			"Valve"
			{
				"Steam"
				{
					"RunningAppID"		"730"
				}
			}
		}
	}
}''';
      expect(io.parseSteamVdfAppId(vdf), 730);
      expect(io.parseSteamVdfAppId('"RunningAppID"\t"0"'), isNull);
      expect(io.parseSteamVdfAppId('nothing'), isNull);
    });

    test('windows registry query', () {
      const out = '''

HKEY_CURRENT_USER\\Software\\Valve\\Steam
    RunningAppID    REG_DWORD    0x2da

''';
      expect(io.parseSteamRegQuery(out), 730);
      expect(io.parseSteamRegQuery('RunningAppID    REG_DWORD    0x0'), isNull);
    });

    test('tasklist csv', () {
      const out = '"System Idle Process","0","Services","0","8 K"\r\n'
          '"cs2.exe","4321","Console","1","2,000 K"\r\n';
      expect(io.parseTasklist(out), ['System Idle Process', 'cs2.exe']);
    });
  });

  test('the factory takes the requested platform, none means no source', () {
    expect(createGameSource(linux: true), isA<AllowlistGameSource>());
    expect(createGameSource(windows: true), isA<AllowlistGameSource>());
    expect(
      createGameSource(linux: false, windows: false, macos: false),
      isNull,
    );
  });
}

class _ThrowingProbe implements GameProbe {
  @override
  Future<Iterable<String>> runningProcessNames() async =>
      throw const FormatException('boom');

  @override
  Future<int?> runningSteamAppId() async => null;

  @override
  Future<String?> steamAppName(int appId) async => null;
}
