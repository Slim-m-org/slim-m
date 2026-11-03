// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The dialog custom emoji are added in: drop, paste or choose any mix of
/// images and zips, stage them in one list of names, and import in one action.
///
/// Planning is `planEmojiPicks`, so a loose image and an image inside a zip
/// take the same name from the same file stem. Several images upload in
/// chunks through `POST /emoji/bulk` ([chunkPlannedEmojiUploads]), because the
/// single upload charges the rate limit per call and a 200-image pack burned
/// the whole budget after ten. A chunk lands whole or refuses whole, so a
/// failure is reported at the chunk it happened in and its images stay in the
/// review list to retry; one image uses `POST /emoji`, which can say it
/// duplicates an existing picture.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../../action_labels.dart';
import '../../../../api_failure.dart';
import '../../../../providers/admin_providers.dart';
import '../../../../providers/providers.dart';
import '../../../../widgets/app_drop_zone.dart';
import '../../../composer/widgets/composer_clipboard_image.dart';
import '../../../composer/widgets/composer_clipboard_paste.dart';
import 'emoji_add_review.dart';
import 'emoji_add_summary.dart';
import 'emoji_bulk_plan.dart';
import 'emoji_intake.dart';
import 'emoji_name.dart';

/// Opens the add dialog with [initial] already staged, as a drop on the page does.
Future<void> showEmojiAddDialog(
  BuildContext context, {
  List<EmojiPick> initial = const [],
}) => showAppSheet<void>(
  context,
  maxWidth: 560,
  scrolls: true,
  semanticLabel: ActionLabels.createEmoji,
  builder: (_) => EmojiAddDialog(initial: initial),
);

class EmojiAddDialog extends ConsumerStatefulWidget {
  const EmojiAddDialog({super.key, this.initial = const []});

  final List<EmojiPick> initial;

  @override
  ConsumerState<EmojiAddDialog> createState() => _EmojiAddDialogState();
}

class _EmojiAddDialogState extends ConsumerState<EmojiAddDialog> {
  final _items = <EmojiReviewItem>[];
  List<SkippedZipEntry> _skipped = const [];
  List<EmojiAddResult> _succeeded = const [];
  List<EmojiAddResult> _failed = const [];
  api.CustomEmoji? _sameImage;
  String? _refusal;
  bool _running = false;
  int _current = 0;
  int _total = 0;
  int _pasted = 0;

  @override
  void initState() {
    super.initState();
    startClipboardImagePaste(_stagePasted);
    if (widget.initial.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ingest(widget.initial);
      });
    }
  }

  @override
  void dispose() {
    stopClipboardImagePaste(_stagePasted);
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  Set<String> get _existing => {
    for (final e
        in ref.read(customEmojiProvider).valueOrNull ?? <api.CustomEmoji>[])
      e.name,
  };

  Future<void> _choose() async {
    final List<EmojiPick> picks;
    try {
      picks = await ref.read(emojiFilesPickerProvider)();
    } catch (error, stack) {
      api.reportFailure(api.LogTag.media, 'choose emoji files', error, stack);
      _refuse('Could not open the file picker.');
      return;
    }
    if (picks.isEmpty || !mounted) return;
    _ingest(picks);
  }

  Future<void> _stagePasted(Uint8List bytes, String filename) async {
    if (_running) return;
    _ingest([EmojiPick(fileName: 'pasted-${++_pasted}.png', bytes: bytes)]);
  }

  Future<void> _pasteFromButton() => pasteClipboardImage(
    (bytes, name) async => _stagePasted(bytes, name),
    (message) {
      if (message != null) _refuse(message);
    },
  );

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isClipboardPasteChord(event) && !_running) {
      unawaited(
        pasteClipboardImageFromKeystroke(
          (bytes, name) async => _stagePasted(bytes, name),
          (message) {
            if (message != null) _refuse(message);
          },
        ),
      );
    }
    return KeyEventResult.ignored;
  }

  Future<void> _drop(List<DropItem> files) async =>
      _ingest(await readDroppedEmoji(files));

  void _ingest(List<EmojiPick> picks) {
    final plan = planEmojiPicks(
      picks,
      existingNames: {..._existing, for (final i in _items) i.normalized},
    );
    if (plan.uploads.isEmpty && plan.skipped.isEmpty) {
      _refuse('No images found.');
      return;
    }
    setState(() {
      if (_items.isEmpty) {
        _skipped = const [];
        _succeeded = const [];
        _failed = const [];
      }
      _refusal = null;
      _sameImage = null;
      _skipped = [..._skipped, ...plan.skipped];
      _items.addAll(plan.uploads.map(EmojiReviewItem.new));
    });
  }

  void _refuse(String message) {
    if (!mounted) return;
    setState(() {
      _running = false;
      _refusal = message;
    });
  }

  // Disposed after the frame: the row's TextField still listens to it until then.
  void _discard(EmojiReviewItem item) =>
      WidgetsBinding.instance.addPostFrameCallback((_) => item.dispose());

  void _remove(int index) => setState(() => _discard(_items.removeAt(index)));

  Future<void> _upload() async {
    final batch = [for (final i in _items) i.edited];
    final items = [..._items];
    setState(() {
      _running = true;
      _current = 0;
      _total = batch.length;
      _refusal = null;
      _sameImage = null;
    });
    final container = ProviderScope.containerOf(context, listen: false);
    final results = batch.length == 1
        ? [await _uploadOne(batch.single)]
        : await _uploadChunks(batch);
    if (results.any((r) => !r.failed)) {
      container.invalidate(customEmojiProvider);
    }
    if (!mounted) return;
    setState(() {
      for (var i = items.length - 1; i >= 0; i--) {
        if (!results[i].failed) {
          _items.remove(items[i]);
          _discard(items[i]);
        }
      }
      _succeeded = [..._succeeded, ...results.where((r) => !r.failed)];
      _failed = results.where((r) => r.failed).toList();
      _running = false;
    });
  }

  Future<EmojiAddResult> _uploadOne(PlannedEmojiUpload upload) async {
    String? reason;
    try {
      final created = await ref
          .read(apiProvider)
          .uploadCustomEmoji(upload.bytes, name: upload.name);
      if (mounted && created.sameImageAs != null) _sameImage = created;
    } on api.ConflictException catch (e, stack) {
      api.reportFailure(api.LogTag.media, 'upload an emoji', e, stack);
      reason = '${emojiShortcode(upload.name)} was refused: ${e.message}.';
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.media, 'upload an emoji', e, stack);
      reason = describeApiFailure(
        'add the ${emojiShortcode(upload.name)} emoji',
        e,
      );
    }
    return EmojiAddResult(upload: upload, reason: reason);
  }

  Future<List<EmojiAddResult>> _uploadChunks(
    List<PlannedEmojiUpload> uploads,
  ) async {
    final client = ref.read(apiProvider);
    final results = <EmojiAddResult>[];
    for (final chunk in chunkPlannedEmojiUploads(uploads)) {
      String? reason;
      try {
        await client.bulkUploadCustomEmoji([
          for (final u in chunk)
            api.EmojiBulkImage(name: u.name, bytes: u.bytes),
        ]);
      } on api.ApiException catch (e, stack) {
        api.reportFailure(
          api.LogTag.media,
          'upload a batch of emoji',
          e,
          stack,
        );
        reason = describeApiFailure('add ${chunk.length} emoji', e);
      }
      results.addAll([
        for (final u in chunk) EmojiAddResult(upload: u, reason: reason),
      ]);
      if (mounted) setState(() => _current += chunk.length);
    }
    return results;
  }

  Future<void> _useExisting(api.CustomEmoji added) async {
    setState(() => _running = true);
    try {
      await ref.read(apiProvider).deleteCustomEmoji(added.id);
      if (mounted) ref.invalidate(customEmojiProvider);
      if (mounted) setState(() => _sameImage = null);
    } on api.ApiException catch (e, stack) {
      api.reportFailure(
        api.LogTag.media,
        'replace an existing emoji',
        e,
        stack,
      );
      _refuse(describeApiFailure('remove the ${added.shortcode} emoji', e));
    }
    if (mounted) setState(() => _running = false);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    ref.watch(customEmojiProvider);
    final problems = reviewProblems(_items, _existing);
    final blocked = problems.any((p) => p != null);
    final finished =
        !_running &&
        (_succeeded.isNotEmpty || _failed.isNotEmpty || _skipped.isNotEmpty);
    final sameImage = _sameImage;

    return AppDropZone(
      enabled: !_running,
      label: 'Drop to add emoji',
      icon: AppIcons.image,
      onDrop: (files) => unawaited(_drop(files)),
      child: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s16,
            0,
            AppSpacing.s16,
            AppSpacing.s16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: AppSpacing.s12,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ActionLabels.createEmoji,
                      style: AppText.body.copyWith(
                        color: tokens.textPrimary,
                        fontWeight: AppWeights.semi,
                      ),
                    ),
                  ),
                  AppIconButton(
                    icon: AppIcons.dismiss,
                    semanticLabel: 'Close',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
              Text(
                dropZoneSupported()
                    ? 'Drop, paste or choose images or a zip, then check the names.'
                    : 'Paste or choose images or a zip, then check the names.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              Wrap(
                spacing: AppSpacing.s8,
                runSpacing: AppSpacing.s8,
                children: [
                  AppButton(
                    label: 'Choose files',
                    icon: AppIcons.add,
                    size: AppButtonSize.sm,
                    disabled: _running,
                    onPressed: _choose,
                  ),
                  AppButton(
                    label: 'Paste image',
                    icon: AppIcons.image,
                    size: AppButtonSize.sm,
                    variant: AppButtonVariant.secondary,
                    disabled: _running,
                    onPressed: _pasteFromButton,
                  ),
                ],
              ),
              if (_refusal case final refusal?)
                AppErrorState(
                  message: refusal,
                  onDismiss: () => setState(() => _refusal = null),
                ),
              if (sameImage != null)
                EmojiSameImageNotice(
                  added: sameImage,
                  existingName: sameImage.sameImageAs!,
                  busy: _running,
                  onUseExisting: () => _useExisting(sameImage),
                  onKeep: () => setState(() => _sameImage = null),
                ),
              if (_items.isNotEmpty)
                EmojiReviewList(
                  items: _items,
                  problems: problems,
                  enabled: !_running,
                  onChanged: () => setState(() {}),
                  onRemove: _remove,
                ),
              if (_running) ...[
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'Uploading $_current of $_total...',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ),
                LinearProgressIndicator(
                  value: _total == 0 ? null : _current / _total,
                ),
              ],
              if (finished)
                EmojiAddSummary(
                  succeeded: _succeeded,
                  failed: _failed,
                  skipped: _skipped,
                ),
              if (_items.isNotEmpty)
                AppButton(
                  label: 'Import ${_items.length} emoji',
                  icon: AppIcons.smile,
                  variant: AppButtonVariant.primary,
                  full: true,
                  disabled: _running || blocked,
                  onPressed: _upload,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
