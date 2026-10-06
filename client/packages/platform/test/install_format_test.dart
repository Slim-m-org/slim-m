// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

InstallFormat resolve({
  String baked = '',
  Map<String, String> env = const {},
  String exe = '/home/user/slimm/slimm_app',
  bool flatpak = false,
}) =>
    resolveInstallFormat(
      baked: baked,
      env: env,
      executablePath: exe,
      flatpakInfoExists: flatpak,
    );

void main() {
  test('a baked format is authoritative over any sniffing', () {
    // Baked rpm even though the environment looks like an AppImage.
    expect(
      resolve(baked: 'rpm', env: {'APPIMAGE': '/x.AppImage'}),
      InstallFormat.rpm,
    );
    expect(resolve(baked: 'AppImage'), InstallFormat.appImage);
    expect(resolve(baked: 'flatpak'), InstallFormat.flatpak);
    expect(resolve(baked: 'deb'), InstallFormat.deb);
    expect(resolve(baked: 'tarball'), InstallFormat.tarball);
  });

  test('APPIMAGE in the environment sniffs as an AppImage', () {
    expect(
        resolve(env: {'APPIMAGE': '/opt/x.AppImage'}), InstallFormat.appImage);
  });

  test('flatpak is sniffed from FLATPAK_ID or /.flatpak-info', () {
    expect(resolve(env: {'FLATPAK_ID': 'top.npcserver.slimm'}),
        InstallFormat.flatpak);
    expect(resolve(flatpak: true), InstallFormat.flatpak);
  });

  test('an executable under a system prefix sniffs as a package', () {
    expect(
        resolve(exe: '/usr/lib64/slim-m-client/slimm_app'), InstallFormat.rpm);
    expect(resolve(exe: '/opt/slim-m/slimm_app'), InstallFormat.rpm);
  });

  test('anything else off disk is treated as a portable tarball', () {
    expect(resolve(exe: '/home/user/Downloads/slimm/slimm_app'),
        InstallFormat.tarball);
  });

  group('the format for a kind of host', () {
    InstallFormat forHost({
      bool web = false,
      bool android = false,
      bool desktop = false,
      InstallFormat sniffed = InstallFormat.tarball,
    }) =>
        installFormatForHost(
          isWeb: web,
          isAndroid: android,
          isDesktop: desktop,
          desktop: () => sniffed,
        );

    test('a sideloaded android build is an apk', () {
      expect(forHost(android: true), InstallFormat.apk);
    });

    test('a desktop host answers what its packaging sniffs as', () {
      expect(
        forHost(desktop: true, sniffed: InstallFormat.flatpak),
        InstallFormat.flatpak,
      );
    });

    test('a host that is neither stays unknown, and never sniffs', () {
      var sniffed = false;
      final format = installFormatForHost(
        isWeb: false,
        isAndroid: false,
        isDesktop: false,
        desktop: () {
          sniffed = true;
          return InstallFormat.tarball;
        },
      );

      expect(format, InstallFormat.unknown);
      expect(sniffed, isFalse);
    });

    test('the web is unknown even where it reports a desktop host', () {
      expect(forHost(web: true, desktop: true), InstallFormat.unknown);
    });
  });
}
