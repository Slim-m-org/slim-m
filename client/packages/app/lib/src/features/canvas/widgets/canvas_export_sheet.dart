// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Export canvas" sheet: copies a board into a new canvas channel, and clears the original when asked (decision 0139).
///
/// The new channel's id is minted once, when the sheet opens, and every attempt sends it, so a retry after a lost answer cannot make a second copy.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../entity_name.dart';
import '../../../ids.dart';
import '../../../permissions.dart';
import '../../../providers/admin_providers.dart';
import '../../../providers/store_stream.dart';
import '../../../providers/providers.dart';
import '../../../providers/toasts.dart';
import '../../../routing/routes.dart';
import '../../channels/providers/channel_by_id_provider.dart';
import '../../channels/providers/channel_permissions.dart';
import '../../channels/widgets/category_choice_row.dart';
import '../../settings/widgets/settings_notice.dart';
import '../../settings/widgets/settings_toggle_row.dart';
import '../providers/canvas_export.dart';

/// Opens the sheet for the board of [channelId].
Future<void> showCanvasExportSheet(BuildContext context, String channelId) {
  return showAppSheet<void>(
    context,
    semanticLabel: 'Export canvas',
    builder: (context) => _CanvasExportSheet(channelId: channelId),
  );
}

/// "<source> canvas", with the source name cut short when the whole would pass the name limit.
@visibleForTesting
String exportDefaultName(String source) {
  const suffix = ' canvas';
  var kept = source.runes.toList();
  String name() => '${String.fromCharCodes(kept)}$suffix';
  while (kept.isNotEmpty && !entityNameValid(name())) {
    kept = kept.sublist(0, kept.length - 1);
  }
  return kept.isEmpty ? 'canvas' : name();
}

class _CanvasExportSheet extends ConsumerStatefulWidget {
  const _CanvasExportSheet({required this.channelId});

  final String channelId;

  @override
  ConsumerState<_CanvasExportSheet> createState() => _CanvasExportSheetState();
}

class _CanvasExportSheetState extends ConsumerState<_CanvasExportSheet> {
  final _exportId = newChannelId();
  final _name = TextEditingController();
  final _categories = StoreStream<List<ChannelCategoryRow>>(
    (s) => s.watchCategories(),
  );
  String? _category;
  bool _prefilled = false;
  bool _call = false;
  bool _clear = false;
  bool _running = false;
  CanvasExportFailure? _failure;

  /// Once any try got no answer it may still commit, so every later try is the identical request.
  bool _unknown = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Fills the name and category from the source once its row is known, unless the person got there first.
  void _prefill(Channel? source) {
    if (_prefilled || source == null) return;
    _prefilled = true;
    if (_name.text.isEmpty) _name.text = exportDefaultName(source.name);
    _category ??= source.categoryId ?? noCategory;
  }

  /// After a lost answer the same request must go again, so the form stops changing.
  bool get _locked => _running || _unknown;

  bool get _canSend =>
      !_running && entityNameValid(_name.text) && (_failure?.canRetry ?? true);

  Future<void> _export(Channel source) async {
    setState(() {
      _running = true;
      _failure = null;
    });
    final toasts = ref.read(toastsProvider.notifier);
    final exporter = ref.read(canvasExporterProvider);
    final navigator = Navigator.of(context);
    final router = GoRouter.of(context);
    final category = _category ?? noCategory;
    try {
      final result = await exporter.export(
        widget.channelId,
        id: _exportId,
        name: _name.text.trim(),
        categoryId: category == noCategory ? null : category,
        voiceEnabled: _call,
        clearSource: _clear,
      );
      if (mounted) navigator.pop();
      toasts.show(
        _confirmation(result),
        severity: AppToastSeverity.success,
        actionLabel: 'Open',
        onAction: () => router.go(Routes.channel(result.channel.id)),
      );
    } on Object catch (error, stack) {
      api.reportFailure(api.LogTag.ui, 'export the canvas', error, stack);
      if (mounted) {
        final failure = CanvasExportFailure.of(error, afterUnknown: _unknown);
        setState(() {
          _running = false;
          _failure = failure;
          _unknown |= failure.kind == CanvasExportFailureKind.unreachable;
        });
      }
    }
  }

  String _confirmation(api.CanvasExportResult result) {
    final spared = result.spared;
    final left = result.left;
    final locked = spared == 0
        ? ''
        : ' $spared locked ${spared == 1 ? 'item' : 'items'} stayed.';
    final uncopied = left == 0
        ? ''
        : left == 1
        ? " 1 item couldn't be copied and stayed on the original."
        : " $left items couldn't be copied and stayed on the original.";
    return 'Exported to ${result.channel.name}.$locked$uncopied';
  }

  String get _label {
    if (_running) return 'Exporting...';
    if (_failure?.canRetry ?? false) return 'Try again';
    if (inputCharCount(_name.text) == 0) return 'Add a channel name';
    if (!entityNameValid(_name.text)) return 'Name is too long';
    return _clear ? 'Export and clear' : 'Export';
  }

  @override
  Widget build(BuildContext context) {
    final source = ref.watch(channelByIdProvider(widget.channelId)).valueOrNull;
    _prefill(source);
    final canManage = ref
        .watch(myPermissionsProvider)
        .hasPermission(Perm.manageChannels);
    final canClear = ref
        .watch(myChannelPermissionsProvider(widget.channelId))
        .hasPermission(Perm.manageCanvas);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Export canvas',
              style: AppText.heading.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s16),
            if (!canManage)
              ..._noPermission()
            else if (source != null)
              ..._form(tokens, source, canClear),
          ],
        ),
      ),
    );
  }

  List<Widget> _noPermission() => [
    const SettingsNotice(
      message: 'You need permission to manage channels to export.',
    ),
    AppButton(
      label: 'Cancel',
      variant: AppButtonVariant.secondary,
      full: true,
      onPressed: () => Navigator.of(context).pop(),
    ),
  ];

  List<Widget> _form(AppTokens tokens, Channel source, bool canClear) {
    final failure = _failure;
    return [
      const _ExportChoice(),
      const SizedBox(height: AppSpacing.s12),
      AppInput(
        controller: _name,
        placeholder: 'Channel name',
        counterMax: entityNameMaxChars,
        autofocus: true,
        enabled: !_locked,
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) {
          if (_canSend) _export(source);
        },
        semanticLabel: 'Channel name',
      ),
      const SizedBox(height: AppSpacing.s8),
      _categoryRow(),
      SettingsToggleRow(
        label: 'Voice call',
        description: 'Lets people talk while they work.',
        value: _call,
        onChanged: _locked ? null : (v) => setState(() => _call = v),
        semanticLabel: 'Let people call in the new channel',
        inset: 0,
      ),
      if (canClear)
        SettingsToggleRow(
          label: 'Clear this canvas after',
          description: 'Removes everything here once the copy is made.',
          value: _clear,
          onChanged: _locked ? null : (v) => setState(() => _clear = v),
          semanticLabel: 'Clear this canvas after exporting',
          inset: 0,
        ),
      if (source.restricted ?? false)
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s4),
          child: Text(
            'Visible to the same people as this channel.',
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
      if (failure != null) ...[
        const SizedBox(height: AppSpacing.s8),
        AppErrorState(message: failure.message),
      ],
      const SizedBox(height: AppSpacing.s12),
      _actions(source),
    ];
  }

  Widget _categoryRow() {
    final store = ref.watch(storeProvider).valueOrNull;
    if (store == null) return const SizedBox.shrink();
    return StreamBuilder<List<ChannelCategoryRow>>(
      stream: _categories.of(store),
      builder: (context, snapshot) {
        final fileable = [
          for (final c in snapshot.data ?? const <ChannelCategoryRow>[])
            if (c.canFile) c,
        ];
        if (fileable.isEmpty) return const SizedBox.shrink();
        final picked = _category ?? noCategory;
        return CategoryChoiceRow(
          categories: fileable,
          value: fileable.any((c) => c.id == picked) ? picked : noCategory,
          onChanged: (id) {
            if (!_locked) setState(() => _category = id);
          },
        );
      },
    );
  }

  Widget _actions(Channel source) {
    final tooLarge = _failure?.kind == CanvasExportFailureKind.tooLarge;
    final cancel = AppButton(
      label: 'Cancel',
      variant: AppButtonVariant.secondary,
      full: true,
      disabled: _running,
      onPressed: () => Navigator.of(context).pop(),
    );
    if (tooLarge) return cancel;
    return Row(
      spacing: AppSpacing.s8,
      children: [
        Expanded(child: cancel),
        Expanded(
          child: AppButton(
            label: _label,
            variant: _clear
                ? AppButtonVariant.danger
                : AppButtonVariant.primary,
            full: true,
            disabled: !_canSend,
            onPressed: () => _export(source),
          ),
        ),
      ],
    );
  }
}

/// The one way to export today, drawn as a chosen row so another can sit beside it later.
class _ExportChoice extends StatelessWidget {
  const _ExportChoice();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Semantics(
      selected: true,
      inMutuallyExclusiveGroup: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s12),
        decoration: BoxDecoration(
          color: tokens.accentSoft,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(color: tokens.accent),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(AppIcons.check, size: AppSizes.icon16, color: tokens.accent),
            const SizedBox(width: AppSpacing.s8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Export to canvas channel',
                    style: AppText.ui.copyWith(color: tokens.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Text(
                    'Copies this board into a new canvas channel.',
                    style: AppText.caption.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
