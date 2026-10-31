// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Installing a module from a package file, and saving one as a file
/// (decision 0090, section 9): the file is read here, checked and described by
/// the server, and goes through the same consent sheet as any unreviewed source.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../../downloads/download_target.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../routing/routes.dart';
import '../../../../widgets/run_guarded.dart';
import '../../../composer/providers/slash_command.dart';
import '../../../modules/providers/app_launch.dart';
import '../../../modules/providers/code_block_runner.dart';
import 'dock_install_consent.dart';

/// A package file the admin chose: its name and what it held.
class DockPackagePick {
  const DockPackagePick({required this.fileName, required this.bytes});
  final String fileName;
  final List<int> bytes;
}

/// Picks a module package; null when nothing was chosen.
typedef DockPackagePicker = Future<DockPackagePick?> Function();

/// Saves [bytes] as [fileName]; false when the admin dismissed the save step.
typedef DockPackageSaver =
    Future<bool> Function(String fileName, List<int> bytes);

/// Injectable because `file_picker` has no platform implementation under test.
final dockPackagePickerProvider = Provider<DockPackagePicker>(
  (ref) => _pickPackage,
);

final dockPackageSaverProvider = Provider<DockPackageSaver>(
  (ref) => _savePackage,
);

/// `FileType.custom`, not a media type: on iOS the latter opens only the Photos picker.
Future<DockPackagePick?> _pickPackage() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: const ['json'],
  );
  final file = files.firstOrNull;
  if (file == null) return null;
  return DockPackagePick(fileName: file.name, bytes: await file.readAsBytes());
}

Future<bool> _savePackage(String fileName, List<int> bytes) async {
  final target = await openDownloadTarget(fileName);
  if (target == null) return false;
  await target.write(bytes);
  return target.finish();
}

/// The name an exported module is saved under.
String dockPackageFileName(String moduleId, String version) =>
    '$moduleId-$version.slimm-module.json';

/// Picks a file, shows what it asks for, and installs it once the admin agrees.
/// Failures land in the caller's persistent error state through [guard].
Future<void> installDockModuleFromFile(
  BuildContext context,
  WidgetRef ref,
  Guard guard,
  void Function(String message) fail,
) async {
  final pick = await ref.read(dockPackagePickerProvider)();
  if (pick == null || !context.mounted) return;
  final Map<String, dynamic> package;
  try {
    package = jsonDecode(utf8.decode(pick.bytes)) as Map<String, dynamic>;
  } on Object {
    fail('Could not read ${pick.fileName}. It is not a module file.');
    return;
  }
  api.DockManifest? manifest;
  final readable = await guard(
    whatFailed: 'read ${pick.fileName}',
    action: () async =>
        manifest = await ref.read(apiProvider).previewDockPackage(package),
  );
  final found = manifest;
  if (!readable || found == null || !context.mounted) return;
  final agreed = await showDockInstallConsent(
    context,
    manifest: found,
    capabilities: newConsentCapabilities(found, null),
    verified: false,
    isUpdate: false,
  );
  if (!agreed || !context.mounted) return;
  final installed = await guard(
    whatFailed: 'install ${found.name}',
    action: () => ref
        .read(apiProvider)
        .installDockPackage(
          package: package,
          version: found.version,
          approvedHostCapabilities: const [],
          reviewedDigest: found.reviewDigest,
        ),
  );
  if (!installed) return;
  ref.invalidate(dockCatalogProvider);
  ref.invalidate(modulePermissionsProvider);
  ref.invalidate(codeBlockRunnerProvider);
  ref.invalidate(slashCommandProvider);
  ref.invalidate(appLaunchProvider);
  if (!context.mounted) return;
  await context.push(
    Routes.adminDockModule(found.id, source: api.kFileDockSource),
  );
}

/// Saves an installed module as a package file.
Future<void> exportDockModuleToFile(
  WidgetRef ref,
  Guard guard,
  api.DockManifest manifest,
) async {
  await guard(
    whatFailed: 'export ${manifest.name}',
    action: () async {
      final package = await ref.read(apiProvider).exportDockModule(manifest.id);
      await ref.read(dockPackageSaverProvider)(
        dockPackageFileName(manifest.id, manifest.version),
        utf8.encode(jsonEncode(package)),
      );
    },
  );
}
