// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:io';

import 'package:path_provider_linux/path_provider_linux.dart';
import 'package:shared_preferences_linux/shared_preferences_linux.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

const noiseKey = 'flutter.slimm.voice.noise_suppression';
const otherKey = 'flutter.slimm.voice.auto_gain';

typedef StoreFactory = SharedPreferencesStorePlatform Function(Directory dir);

class _DirPathProvider extends PathProviderLinux {
  _DirPathProvider(this.dir);

  final Directory dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir.path;
}

/// The plugin's own Linux store over [dir], the one the app shipped with.
SharedPreferencesStorePlatform stockLinuxStore(Directory dir) =>
    SharedPreferencesLinux()..pathProvider = _DirPathProvider(dir);

File prefsFile(Directory dir) => File('${dir.path}/shared_preferences.json');

/// What a kill during an in-place rewrite leaves behind.
void truncateLikeAKill(Directory dir, {required bool toEmpty}) {
  final file = prefsFile(dir);
  final text = file.readAsStringSync();
  file.writeAsStringSync(toEmpty ? '' : text.substring(0, text.length ~/ 2));
}
