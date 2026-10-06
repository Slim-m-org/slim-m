// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Bulk emoji upload from a `.zip` - backlog #137.
///
/// One custom emoji per image inside the zip, named after its file stem
/// Discord-style (`party_blob.gif` becomes `:party_blob:`), through the same
/// name rules `EmojiUploadCard` applies one at a time; see
/// `emoji_bulk_plan.dart` for the pure derivation this widget only drives.
///
/// Images upload in chunks through `POST /emoji/bulk`
/// ([chunkPlannedEmojiUploads]), not one `POST /emoji` per image: the single
/// upload charges the rate limit once per call, so importing a 200-image pack
/// one image at a time burned the whole budget after ten and refused the
/// other hundred and ninety. A chunk either lands whole or refuses whole, so
/// a failure is reported and retried at the chunk it happened in - never one
/// line per image, and never by re-running images that already succeeded.
library;

import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../api_failure.dart';
import '../../providers/admin_providers.dart';
import '../../providers/providers.dart';
import '../../widgets/app_drop_zone.dart';
import '../../widgets/settings_section_header.dart';
import 'emoji_bulk_plan.dart';
import 'emoji_name.dart';

/// Picks a zip file and returns its bytes, or null if nothing was chosen.
typedef EmojiZipPicker = Future<List<int>?> Function();

/// Injectable for the same reason `emojiImagePickerProvider` is:
/// `file_picker` has no platform implementation under test.
final emojiZipPickerProvider = Provider<EmojiZipPicker>((ref) => _pickZipBytes);

Future<List<int>?> _pickZipBytes() async {
  final file = await FilePicker.pickFile(
    type: FileType.custom,
    allowedExtensions: const ['zip'],
  );
  // readAsBytes streams from disk since eager loading OOMs on a large pick.
  return file?.readAsBytes();
}

enum _Outcome { uploaded, failed }

class _Result {
  const _Result({required this.upload, required this.outcome, this.reason});

  final PlannedEmojiUpload upload;
  final _Outcome outcome;
  final String? reason;
}

class EmojiBulkUploadCard extends ConsumerStatefulWidget {
  const EmojiBulkUploadCard({super.key});

  @override
  ConsumerState<EmojiBulkUploadCard> createState() =>
      _EmojiBulkUploadCardState();
}

/// Watches `customEmojiProvider` in [build], not only reads it from
/// `_pickAndRun`: that way the deployment's current emoji names are already
/// resolved by the time a tap can reach the collision check, rather than
/// depending on whichever sibling widget happens to watch the provider first.
class _EmojiBulkUploadCardState extends ConsumerState<EmojiBulkUploadCard> {
  bool _running = false;
  int _current = 0;
  int _total = 0;
  String? _refusal;
  List<SkippedZipEntry> _skipped = const [];

  /// Every image this run (across a first pass and any retries) has actually
  /// created, so a retry never re-sends one that already succeeded.
  List<_Result> _succeeded = const [];

  /// The most recent pass's own failures: what the "Retry failed" button
  /// retries, and what `_BulkSummary` reports.
  List<_Result> _failed = const [];

  Future<void> _pickAndRun() async {
    final List<int>? bytes;
    try {
      bytes = await ref.read(emojiZipPickerProvider)();
    } catch (e) {
      _refuse('Could not open the file picker.');
      return;
    }
    if (bytes == null || !mounted) return;
    await _runImport(bytes);
  }

  /// One dropped or picked zip's own bytes, decoded and planned into the
  /// same chunked [_runChunks] path: the picker's own `_pickAndRun` and
  /// [_handleDrop] both land here, so a drop never invents a second,
  /// unchunked import route with its own failure/retry behaviour.
  Future<void> _runImport(List<int> bytes) async {
    final List<ZipEntryData> entries;
    try {
      entries = decodeEmojiZipEntries(bytes);
    } catch (e) {
      _refuse('That file could not be read as a zip.');
      return;
    }

    final existing = ref.read(customEmojiProvider).valueOrNull ?? const [];
    final plan = planEmojiZip(
      entries,
      existingNames: {for (final e in existing) e.name},
    );
    if (plan.uploads.isEmpty && plan.skipped.isEmpty) {
      _refuse('That zip has no images in it.');
      return;
    }

    setState(() {
      _refusal = null;
      _skipped = plan.skipped;
      _succeeded = const [];
      _failed = const [];
    });
    await _runChunks(plan.uploads);
  }

  Future<void> _retryFailed() async {
    final retrying = _failed.map((r) => r.upload).toList(growable: false);
    if (retrying.isEmpty) return;
    await _runChunks(retrying);
  }

  /// Uploads [uploads] in chunks sized to what `POST /emoji/bulk` accepts
  /// ([chunkPlannedEmojiUploads]). A chunk that fails marks every image in it
  /// failed with the one reason the server gave, rather than guessing which
  /// image in the chunk was actually at fault - the same all-or-nothing
  /// contract the server itself keeps for one request.
  Future<void> _runChunks(List<PlannedEmojiUpload> uploads) async {
    setState(() {
      _running = true;
      _current = 0;
      _total = uploads.length;
      _failed = const [];
    });

    final newlyFailed = <_Result>[];
    var anySucceeded = false;
    for (final chunk in chunkPlannedEmojiUploads(uploads)) {
      if (!mounted) return;
      try {
        await ref.read(apiProvider).bulkUploadCustomEmoji([
          for (final upload in chunk)
            api.EmojiBulkImage(name: upload.name, bytes: upload.bytes),
        ]);
        anySucceeded = true;
        if (!mounted) return;
        setState(() {
          _succeeded = [
            ..._succeeded,
            for (final upload in chunk)
              _Result(upload: upload, outcome: _Outcome.uploaded),
          ];
          _current += chunk.length;
        });
      } on api.ApiException catch (e) {
        final what = chunk.length == 1
            ? 'add ${emojiShortcode(chunk.single.name)}'
            : 'add ${chunk.length} emoji';
        final reason = describeApiFailure(what, e);
        newlyFailed.addAll([
          for (final upload in chunk)
            _Result(upload: upload, outcome: _Outcome.failed, reason: reason),
        ]);
        if (!mounted) return;
        setState(() => _current += chunk.length);
      }
    }

    if (anySucceeded) {
      ref.invalidate(customEmojiProvider);
    }
    if (!mounted) return;
    setState(() {
      _failed = newlyFailed;
      _running = false;
    });
  }

  void _refuse(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _refusal = message;
    });
  }

  /// The card's own drop target: exactly one `.zip`, the same shape the
  /// picker already enforces through `allowedExtensions`. A wrong drop is
  /// refused through the same [_refuse] the picker's own failures use,
  /// never a second, differently-worded rejection.
  Future<void> _handleDrop(List<DropItem> files) async {
    if (files.length != 1) {
      _refuse('Drop one zip file at a time.');
      return;
    }
    final file = files.first;
    if (file is DropItemDirectory ||
        !file.name.toLowerCase().endsWith('.zip')) {
      _refuse('Drop a .zip file to import emoji.');
      return;
    }
    await _runImport(await file.readAsBytes());
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final finished =
        !_running &&
        (_succeeded.isNotEmpty || _failed.isNotEmpty || _skipped.isNotEmpty);
    ref.watch(customEmojiProvider); // see the class doc comment for why

    return AppDropZone(
      enabled: !_running,
      label: 'Drop to import emoji',
      icon: AppIcons.fileArchive,
      onDrop: (files) => unawaited(_handleDrop(files)),
      child: SettingsSectionCard(
        title: 'Bulk import from a zip',
        children: [
          Text(
            'Each image becomes an emoji named after its file.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s12),
          if (_refusal case final refusal?) ...[
            AppCallout(tone: AppCalloutTone.warn, child: Text(refusal)),
            const SizedBox(height: AppSpacing.s12),
          ],
          if (_running) ...[
            Semantics(
              liveRegion: true,
              child: Text(
                'Uploading $_current of $_total...',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
            LinearProgressIndicator(
              value: _total == 0 ? null : _current / _total,
            ),
            const SizedBox(height: AppSpacing.s12),
          ],
          if (finished) ...[
            _BulkSummary(
              succeeded: _succeeded,
              failed: _failed,
              skipped: _skipped,
            ),
            const SizedBox(height: AppSpacing.s12),
          ],
          if (finished && _failed.isNotEmpty) ...[
            AppButton(
              label: 'Retry ${_failed.length} failed',
              icon: AppIcons.retry,
              full: true,
              disabled: _running,
              onPressed: _retryFailed,
            ),
            const SizedBox(height: AppSpacing.s12),
          ],
          AppButton(
            label: finished ? 'Import another zip' : 'Choose a zip file',
            icon: AppIcons.fileArchive,
            full: true,
            disabled: _running,
            onPressed: _pickAndRun,
          ),
        ],
      ),
    );
  }
}

/// The finished (or partly finished) run's own report.
///
/// Failures and pre-upload skips are grouped by their own reason rather than
/// listed one line per file: a rate-limit refusal or a shared cause behind a
/// whole `POST /emoji/bulk` chunk otherwise repeats itself once per image in
/// that chunk, which is exactly the wall of near-identical lines a 200-image
/// pack used to produce. A cause only one file hit still names that file, so
/// nothing about the ordinary "one image was bad" case gets vaguer.
class _BulkSummary extends StatelessWidget {
  const _BulkSummary({
    required this.succeeded,
    required this.failed,
    required this.skipped,
  });

  final List<_Result> succeeded;
  final List<_Result> failed;
  final List<SkippedZipEntry> skipped;

  @override
  Widget build(BuildContext context) {
    final total = succeeded.length + failed.length + skipped.length;
    final allGood = succeeded.length == total;

    final groups = <String, List<String>>{};
    for (final r in failed) {
      (groups[r.reason ?? 'failed'] ??= []).add(r.upload.fileName);
    }
    for (final s in skipped) {
      (groups[s.reason] ??= []).add(s.fileName);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppCallout(
          tone: allGood ? AppCalloutTone.accent : AppCalloutTone.warn,
          child: Text(
            'Added ${succeeded.length} of $total '
            'image${total == 1 ? '' : 's'}.',
          ),
        ),
        for (final entry in groups.entries)
          _FailureLine(fileNames: entry.value, reason: entry.key),
      ],
    );
  }
}

/// One grouped failure line: a single file names itself, and more than one
/// sharing a reason collapse into a count rather than repeating the line.
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.fileNames, required this.reason});

  final List<String> fileNames;
  final String reason;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final label = fileNames.length == 1
        ? '${fileNames.single}: $reason'
        : '${fileNames.length} images could not be added: $reason';
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s8),
      child: Text(
        label,
        style: AppText.caption.copyWith(color: tokens.dangerText),
      ),
    );
  }
}
