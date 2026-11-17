// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Appearance > Background: a picture behind the panes on this
/// device, with how far it fades, an optional blur and an edge vignette.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show LogTag, reportFailure;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/run_guarded.dart';
import '../../background/providers/app_background_controller.dart';
import '../../background/widgets/app_background_host.dart';
import '../../messages/widgets/attachment_picker.dart';
import '../providers/background_from_theme.dart';
import 'background_picture_menu.dart';
import 'background_preview.dart';
import 'settings_control_column.dart';
import 'settings_info_line.dart';
import 'settings_section_header.dart';
import 'settings_slider_row.dart';
import 'settings_toggle_row.dart';

class BackgroundSettingsCard extends ConsumerStatefulWidget {
  const BackgroundSettingsCard({super.key});

  static const Key pictureRowKey = Key('background_picture_row');
  static const Key removeKey = Key('background_remove_picture');
  static const Key dimSliderKey = Key('background_dim_slider');
  static const Key blurSliderKey = Key('background_blur_slider');

  @override
  ConsumerState<BackgroundSettingsCard> createState() => _State();
}

class _State extends ConsumerState<BackgroundSettingsCard>
    with GuardedActionState<BackgroundSettingsCard> {
  AppBackgroundController get _controller =>
      ref.read(appBackgroundControllerProvider.notifier);

  /// Any change made here makes the settings the person's own, not a theme's.
  void _madeOwn() =>
      unawaited(ref.read(backgroundFromThemeProvider.notifier).clear());

  Future<void> _remove() async {
    _madeOwn();
    await _controller.remove();
  }

  Future<void> _openMenu(BuildContext row) async {
    final has = ref.read(appBackgroundControllerProvider).hasImage;
    final action = await showBackgroundPictureMenu(row, canRemove: has);
    if (action == null || !mounted) return;
    clearActionError();
    switch (action) {
      case BackgroundPictureAction.remove:
        await _remove();
      case BackgroundPictureAction.choose:
        await _pick(AttachmentSource.photoLibrary);
      case BackgroundPictureAction.browse:
        await _pick(AttachmentSource.stillImageFiles);
    }
  }

  Future<void> _pick(AttachmentSource source) async {
    final Uint8List bytes;
    try {
      final PlatformFile? file = await ref.read(
        attachmentPickerProvider(source),
      )();
      if (file == null) return;
      bytes = await file.readAsBytes();
    } catch (e, stack) {
      reportFailure(LogTag.media, 'pick a background picture', e, stack);
      setActionError('Could not open that photo.');
      return;
    }
    if (!mounted) return;
    if (await _controller.importPicture(bytes)) {
      _madeOwn();
    } else {
      setActionError('That picture could not be used. Try another.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final settings = ref.watch(appBackgroundControllerProvider);
    final plain = !backgroundWanted(ref, context) && settings.hasImage;
    final shown = settings.hasImage && !plain;
    final from = ref.watch(backgroundFromThemeProvider);
    final inColumn = SettingsControlColumn.widthOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final beside =
            inColumn != null && SettingsControlColumn.besideAt(box.maxWidth);
        return SettingsSectionCard(
          title: 'Background',
          description: 'A picture behind the chat, kept on this device.',
          children: [
            _pictureRow(tokens, settings),
            if (actionError != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: AppErrorState(
                  message: actionError!,
                  onDismiss: clearActionError,
                ),
              ),
            if (plain) const SettingsInfoLine('Off while high contrast is on.'),
            if (shown && beside)
              _PreviewBeside(
                column: inColumn,
                controls: _controls(tokens, settings),
              ),
            if (shown && !beside) ...[
              const BackgroundPreview(),
              ..._controls(tokens, settings),
            ],
            if (shown && from != null)
              SettingsInfoLine('Dim, blur and vignette came with $from.'),
          ],
        );
      },
    );
  }

  Widget _pictureRow(
    AppTokens tokens,
    AppBackgroundSettings settings,
  ) => Builder(
    builder: (row) => AppListRow(
      key: BackgroundSettingsCard.pictureRowKey,
      label: 'Picture',
      meta: settings.hasImage ? 'Custom' : 'None',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          if (settings.hasImage)
            AppIconButton(
              key: BackgroundSettingsCard.removeKey,
              icon: AppIcons.dismiss,
              size: AppIconButtonSize.sm,
              semanticLabel: 'Remove picture',
              tooltip: 'Remove picture',
              onPressed: () {
                clearActionError();
                unawaited(_remove());
              },
            ),
          // Down for the menu from 600 wide, right for the sheet below it, like SettingsSelectRow.
          Icon(
            MediaQuery.sizeOf(context).width >= kCompactWidth
                ? AppIcons.chevronDown
                : AppIcons.chevronRight,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
        ],
      ),
      onTap: () => unawaited(_openMenu(row)),
    ),
  );

  List<Widget> _controls(AppTokens tokens, AppBackgroundSettings settings) {
    final min = settings.minimumDimFor(tokens);
    final dim = math.max(
      min,
      effectiveBackgroundDim(tokens, settings.dim, settings.range),
    );
    return [
      SettingsSliderRow(
        sliderKey: BackgroundSettingsCard.dimSliderKey,
        label: 'Dim',
        valueLabel: '${(dim * 100).round()}%',
        value: dim.clamp(min, kBackgroundMaxDim),
        min: min,
        max: kBackgroundMaxDim,
        minLabel: '${(min * 100).round()}%',
        maxLabel: '${(kBackgroundMaxDim * 100).round()}%',
        divisions: ((kBackgroundMaxDim - min) / 0.05).round().clamp(1, 20),
        onChanged: (v) {
          _madeOwn();
          unawaited(_controller.setDim(v));
        },
      ),
      SettingsSliderRow(
        sliderKey: BackgroundSettingsCard.blurSliderKey,
        label: 'Blur',
        valueLabel: '${(settings.blur * 100).round()}%',
        value: settings.blur,
        min: 0,
        max: 1,
        minLabel: '0%',
        maxLabel: '100%',
        divisions: 10,
        onChanged: (v) {
          _madeOwn();
          unawaited(_controller.setBlur(v));
        },
      ),
      SettingsToggleRow(
        label: 'Vignette',
        description: 'Fade the edges.',
        value: settings.vignette,
        semanticLabel: 'Vignette',
        onChanged: (v) {
          _madeOwn();
          unawaited(_controller.setVignette(v));
        },
      ),
    ];
  }
}

/// The preview filling the left of the card, as tall as the controls beside
/// it in the control column.
class _PreviewBeside extends StatelessWidget {
  const _PreviewBeside({required this.column, required this.controls});

  final double column;
  final List<Widget> controls;

  @override
  Widget build(BuildContext context) {
    final controlsWidth = column + AppSlider.trackInset * 2;
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.s16),
      child: Stack(
        children: [
          Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: controlsWidth,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: controls,
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: AppSpacing.s16,
            bottom: AppSpacing.s16,
            right: controlsWidth,
            child: const BackgroundPreview(fill: true),
          ),
        ],
      ),
    );
  }
}
