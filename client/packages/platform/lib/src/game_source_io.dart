// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The host side of game detection: process names and Steam's own record of
/// what it is running. Everything here is read on demand and only ever
/// matched against the allowlist by the caller.
library;

import 'dart:convert';
import 'dart:io';

import 'game_source.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

GameSource? createGameSource({bool? linux, bool? windows, bool? macos}) {
  final supported = (linux ?? Platform.isLinux) ||
      (windows ?? Platform.isWindows) ||
      (macos ?? Platform.isMacOS);
  return supported ? AllowlistGameSource(SystemGameProbe()) : null;
}

/// The app id in Steam's `registry.vdf`, or null when it is 0 or absent.
int? parseSteamVdfAppId(String vdf) {
  final match = RegExp(r'"RunningAppID"\s+"(\d+)"').firstMatch(vdf);
  final id = int.tryParse(match?.group(1) ?? '');
  return id == null || id == 0 ? null : id;
}

/// The library folders listed in Steam's `libraryfolders.vdf`.
List<String> parseSteamLibraryPaths(String vdf) => [
      for (final match in RegExp(r'"path"\s+"([^"]+)"').allMatches(vdf))
        match.group(1)!.replaceAll(r'\\', r'\'),
    ];

/// The `name` in an `appmanifest_<id>.acf`, or null.
String? parseAppManifestName(String acf) =>
    RegExp(r'"name"\s+"([^"]*)"').firstMatch(acf)?.group(1);

/// The DWORD in `reg query ... /v RunningAppID` output, or null.
int? parseSteamRegQuery(String output) {
  final match = RegExp(
    r'RunningAppID\s+REG_DWORD\s+0x([0-9a-fA-F]+)',
  ).firstMatch(output);
  final id = int.tryParse(match?.group(1) ?? '', radix: 16);
  return id == null || id == 0 ? null : id;
}

/// Image names from `tasklist /fo csv /nh`.
Iterable<String> parseTasklist(String output) sync* {
  for (final line in const LineSplitter().convert(output)) {
    final match = RegExp(r'^"([^"]+)"').firstMatch(line);
    if (match != null) yield match.group(1)!;
  }
}

class SystemGameProbe implements GameProbe {
  @override
  Future<Iterable<String>> runningProcessNames() async {
    if (Platform.isLinux) return _linuxProcesses();
    if (Platform.isWindows) {
      final result = await Process.run('tasklist', ['/fo', 'csv', '/nh']);
      return parseTasklist(result.stdout as String);
    }
    final result = await Process.run('ps', ['-axco', 'comm']);
    return const LineSplitter().convert(result.stdout as String);
  }

  Future<Iterable<String>> _linuxProcesses() async {
    final names = <String>[];
    await for (final entry in Directory('/proc').list()) {
      final pid = entry.path.split('/').last;
      if (int.tryParse(pid) == null) continue;
      try {
        names.add(await File('${entry.path}/comm').readAsString());
      } on FileSystemException catch (error, stack) {
        AppLog.swallowed(
            LogTag.platform, 'linux processes failed, ignored', error, stack);
        continue;
      }
    }
    return names;
  }

  /// Steam's install root, where `steamapps/libraryfolders.vdf` lives.
  Future<String?> _steamRoot() async {
    if (Platform.isWindows) {
      final result = await Process.run('reg', [
        'query',
        r'HKCU\Software\Valve\Steam',
        '/v',
        'SteamPath',
      ]);
      final match = RegExp(r'SteamPath\s+REG_SZ\s+(.+)')
          .firstMatch(result.stdout as String);
      return match?.group(1)?.trim();
    }
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final candidates = Platform.isMacOS
        ? ['$home/Library/Application Support/Steam']
        : [
            '$home/.steam/steam',
            '$home/.local/share/Steam',
            '$home/.var/app/com.valvesoftware.Steam/.local/share/Steam',
          ];
    for (final path in candidates) {
      if (await File('$path/steamapps/libraryfolders.vdf').exists()) {
        return path;
      }
    }
    return null;
  }

  @override
  Future<String?> steamAppName(int appId) async {
    try {
      final root = await _steamRoot();
      if (root == null) return null;
      final libraries = parseSteamLibraryPaths(
        await File('$root/steamapps/libraryfolders.vdf').readAsString(),
      );
      for (final library in {root, ...libraries}) {
        final manifest = File('$library/steamapps/appmanifest_$appId.acf');
        if (await manifest.exists()) {
          return parseAppManifestName(await manifest.readAsString());
        }
      }
    } on Object catch (error, stack) {
      AppLog.swallowed(
          LogTag.platform, 'steam app name failed, ignored', error, stack);
      return null;
    }
    return null;
  }

  @override
  Future<int?> runningSteamAppId() async {
    if (Platform.isWindows) {
      final result = await Process.run('reg', [
        'query',
        r'HKCU\Software\Valve\Steam',
        '/v',
        'RunningAppID',
      ]);
      return parseSteamRegQuery(result.stdout as String);
    }
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final candidates = Platform.isMacOS
        ? ['$home/Library/Application Support/Steam/registry.vdf']
        : [
            '$home/.steam/registry.vdf',
            '$home/.var/app/com.valvesoftware.Steam/.steam/registry.vdf',
          ];
    for (final path in candidates) {
      final file = File(path);
      if (await file.exists()) {
        return parseSteamVdfAppId(await file.readAsString());
      }
    }
    return null;
  }
}
