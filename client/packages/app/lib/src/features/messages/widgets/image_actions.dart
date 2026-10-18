// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What Copy image and Save image do, shared by the image menu and the
/// viewer header so one failure reads the same wherever it surfaces.
///
/// Each returns null on success or a sentence for [AppErrorState], the same
/// contract `runGuarded` uses.
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import '../../../api_failure.dart';
import '../../../providers/toasts.dart';
import 'image_export.dart';

final clipboardImageWriterProvider = Provider<ClipboardImageWriter>(
  (ref) => const PlatformClipboardImageWriter(),
);

/// Puts [image] on the system clipboard.
///
/// [loadBytes] is passed on unawaited: a browser only honours a clipboard
/// write started inside the gesture that asked for it.
Future<String?> copyImageToClipboard(
  WidgetRef ref,
  api.Attachment image,
  Future<Uint8List> Function() loadBytes,
) async {
  try {
    await ref.read(clipboardImageWriterProvider).writeImage(loadBytes());
    ref
        .read(toastsProvider.notifier)
        .show('Image copied.', severity: AppToastSeverity.success);
    return null;
  } on ClipboardImageWriteException catch (e, stack) {
    api.AppLog.swallowed(
      api.LogTag.media,
      'Could not copy the image; showing the reason',
      e,
      stack,
    );
    return e.message;
  } on api.ApiException catch (e, stack) {
    api.AppLog.swallowed(
      api.LogTag.media,
      'Could not copy the image; showing the reason',
      e,
      stack,
    );
    return describeApiFailure('copy ${image.filename}', e);
  } catch (error, stack) {
    api.reportFailure(api.LogTag.media, 'copy the image', error, stack);
    return 'Could not copy ${image.filename}.';
  }
}

/// Saves [image] to the photo library, a file the reader names, or a browser
/// download, whichever the platform's [ImageExporter] does.
Future<String?> saveImageToDevice(
  WidgetRef ref,
  api.Attachment image,
  Future<Uint8List> Function() loadBytes,
) async {
  final name = image.filename;
  try {
    final exporter = ref.read(imageExporterProvider);
    final saved = await exporter.save(await loadBytes(), filename: name);
    if (saved) {
      ref
          .read(toastsProvider.notifier)
          .show(
            exporter.savesToLibrary ? 'Saved to photos.' : 'Saved.',
            severity: AppToastSeverity.success,
          );
    }
    return null;
  } on api.ApiException catch (e, stack) {
    api.AppLog.swallowed(
      api.LogTag.media,
      'Could not save the image; showing the reason',
      e,
      stack,
    );
    return describeApiFailure('save $name', e);
  } on PhotoLibraryDenied catch (error, stack) {
    api.AppLog.swallowed(
      api.LogTag.media,
      'Could not save the image; showing the reason',
      error,
      stack,
    );
    return 'Could not save $name: allow photo access for slim-m in Settings.';
  } catch (error, stack) {
    api.reportFailure(api.LogTag.media, 'save the image', error, stack);
    return 'Could not save $name.';
  }
}
