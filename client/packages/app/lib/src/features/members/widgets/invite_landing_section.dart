// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin's controls for the invite landing card: the Space's name, a short
/// description, a banner, an icon, and a live preview of the card a visitor
/// will see.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../settings/providers/display_preferences.dart';
import '../providers/member_presence.dart';
import '../../../providers/providers.dart';
import '../../channels/widgets/channel_rail_frame.dart' show serverInfoProvider;
import '../../messages/widgets/attachment_picker.dart';
import 'avatar_crop_sheet.dart';
import '../../messages/widgets/image_downscale.dart';
import '../../messages/widgets/image_drop_zone.dart';
import 'invite_landing_card.dart';
import 'invite_landing_view.dart';
import '../../settings/widgets/join_policy_row.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_detail_row.dart';
import '../../settings/widgets/settings_field.dart';
import '../../settings/widgets/settings_section_header.dart';
import '../../../widgets/space_icon.dart';
import '../../../widgets/space_name_field.dart';

// The server's caps on the two pictures; a pick past either is shrunk first.
const int _bannerMaxBytes = 4 * 1024 * 1024;
const int _iconMaxBytes = 512 * 1024;

/// The longer side a banner is shrunk to: twice the card's width, for dense screens.
const int _bannerMaxEdge = 1280;

/// The edge a cropped icon is reduced to; it is never drawn above 40 points.
const int _iconEdge = 192;

/// Matches the server's cap on a description.
const int kInviteDescriptionMaxChars = api.InputLimits.spaceDescription;

final _bannerBytesProvider = FutureProvider.autoDispose.family<Uint8List, int>(
  (ref, updatedAt) async =>
      (await ref.watch(apiProvider).fetchSpaceBanner()).bytes,
);

class InviteLandingSection extends ConsumerStatefulWidget {
  const InviteLandingSection({super.key});

  @override
  ConsumerState<InviteLandingSection> createState() =>
      _InviteLandingSectionState();
}

class _InviteLandingSectionState extends ConsumerState<InviteLandingSection>
    with GuardedActionState<InviteLandingSection> {
  final _description = TextEditingController();
  String _saved = '';
  bool _seeded = false;
  bool _busy = false;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  void _seed(api.SpaceSettings settings) {
    if (_seeded) return;
    _seeded = true;
    _saved = settings.description;
    _description.text = settings.description;
  }

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    setState(() => _busy = true);
    clearActionError();
    final ok = await guard(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(spaceSettingsProvider);
  }

  Future<void> _saveDescription() async {
    final text = _description.text.trim();
    await _run('save the description', () async {
      final updated = await ref
          .read(apiProvider)
          .setSpaceSettings(description: text);
      _saved = updated.description;
      _description.text = updated.description;
    });
  }

  Future<void> _chooseBanner() async {
    final file = await ref.read(
      attachmentPickerProvider(AttachmentSource.photoLibrary),
    )();
    if (file == null || !mounted) return;
    await _setBanner(await file.readAsBytes());
  }

  /// A picked or dropped banner, shrunk to fit the server's cap.
  Future<void> _setBanner(Uint8List picked) async {
    final bytes = await downscaledToFit(
      picked,
      maxEdge: _bannerMaxEdge,
      maxBytes: _bannerMaxBytes,
    );
    await _run(
      'upload the banner',
      () => ref.read(apiProvider).uploadSpaceBanner(bytes),
    );
  }

  Future<void> _chooseIcon() async {
    final file = await ref.read(
      attachmentPickerProvider(AttachmentSource.photoLibrary),
    )();
    if (file == null || !mounted) return;
    await _setIcon(await file.readAsBytes());
  }

  /// A picked or dropped icon: cropped square, then minified to fit.
  Future<void> _setIcon(Uint8List picked) async {
    if (!mounted) return;
    final cropped = await showAvatarCropSheet(context, picked, circular: false);
    if (cropped == null || !mounted) return;
    final bytes = await minifiedPng(cropped, width: _iconEdge) ?? cropped;
    final safe = await downscaledToFit(
      bytes,
      maxEdge: _iconEdge,
      maxBytes: _iconMaxBytes,
    );
    await _run(
      'upload the icon',
      () => ref.read(apiProvider).uploadSpaceIcon(safe),
    );
    ref.invalidate(serverInfoProvider);
  }

  Future<void> _removeIcon() async {
    await _run(
      'remove the icon',
      () => ref.read(apiProvider).deleteSpaceIcon(),
    );
    ref.invalidate(serverInfoProvider);
  }

  Widget? _banner(int? updatedAt) {
    if (updatedAt == null) return null;
    final bytes = ref.watch(_bannerBytesProvider(updatedAt)).valueOrNull;
    if (bytes == null) {
      return ColoredBox(
        color: Theme.of(context).extension<AppTokens>()!.surfaceSunken,
      );
    }
    return Image.memory(bytes, fit: BoxFit.cover);
  }

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(spaceSettingsProvider);
    final loaded = settings.valueOrNull;
    if (loaded == null) {
      return SettingsSectionCard(
        title: 'Space profile',
        children: settings.hasError
            ? [
                SettingsCardBlock(
                  children: [
                    AppErrorState(
                      message: 'Could not load the Space profile.',
                      onRetry: () => ref.invalidate(spaceSettingsProvider),
                    ),
                  ],
                ),
              ]
            : const [SizedBox(height: AppSpacing.s48)],
      );
    }
    _seed(loaded);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSectionCard(
          title: 'Space profile',
          description: 'How the Space looks in invites and setup.',
          children: _profileRows(loaded),
        ),
        SettingsSectionCard(
          title: 'Landing page',
          description: 'What an invite link shows before sign-in.',
          children: _landingRows(loaded),
        ),
      ],
    );
  }

  Widget _droppable({
    required String label,
    required Future<void> Function(Uint8List bytes) onImage,
    required Widget child,
  }) => ImageDropZone(
    enabled: !_busy,
    label: label,
    onImage: (bytes, _) => unawaited(onImage(bytes)),
    onRejected: setActionError,
    child: child,
  );

  Widget _pictureRow({
    required String label,
    required bool isSet,
    required VoidCallback onChoose,
    required VoidCallback onRemove,
  }) => SettingsDetailRow(
    icon: AppIcons.image,
    title: label,
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        AppButton(
          label: isSet ? 'Replace' : 'Choose',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          disabled: _busy,
          semanticLabel:
              '${isSet ? 'Replace' : 'Choose'} ${label.toLowerCase()}',
          onPressed: onChoose,
        ),
        if (isSet)
          AppIconButton(
            icon: AppIcons.dismiss,
            size: AppIconButtonSize.sm,
            iconSize: AppSizes.icon16,
            semanticLabel: 'Remove ${label.toLowerCase()}',
            tooltip: 'Remove ${label.toLowerCase()}',
            onPressed: _busy ? null : onRemove,
          ),
      ],
    ),
  );

  InviteLandingCard _card(api.SpaceSettings loaded, {String? invitedBy}) =>
      InviteLandingCard(
        name: loaded.name,
        memberCount: ref.watch(membersProvider).valueOrNull?.length ?? 0,
        description: _description.text.trim(),
        banner: _banner(loaded.bannerUpdatedAt),
        icon: loaded.iconUpdatedAt == null
            ? null
            : SpaceIcon(updatedAt: loaded.iconUpdatedAt, size: kInviteIconSize),
        invitedBy: invitedBy,
        use24Hour: watchUse24Hour(ref, context),
      );

  Future<void> _previewAsVisitor(api.SpaceSettings loaded) {
    final me = ref.read(meProvider).valueOrNull?.displayName;
    return showAppSheet<void>(
      context,
      builder: (sheetContext) => InviteLandingView(
        card: _card(loaded, invitedBy: me),
        onBack: () => Navigator.of(sheetContext).pop(),
        note: 'This is what someone opening one of your invites sees.',
      ),
    );
  }

  List<Widget> _profileRows(api.SpaceSettings loaded) {
    final changed = _description.text.trim() != _saved;
    final bannerSet = loaded.bannerUpdatedAt != null;
    final iconSet = loaded.iconUpdatedAt != null;
    return [
      SettingsCardBlock(
        children: [
          SettingsField(
            label: 'Name',
            child: SpaceNameField(saved: loaded.name),
          ),
          SettingsField(
            label: 'Description',
            child: AppInput(
              controller: _description,
              placeholder: 'Short description',
              semanticLabel: 'Description',
              enabled: !_busy,
              minLines: 2,
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              inputFormatters: [
                LengthLimitingTextInputFormatter(kInviteDescriptionMaxChars),
              ],
              onChanged: (_) => setState(() {}),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: AppButton(
              label: 'Save description',
              variant: AppButtonVariant.primary,
              size: AppButtonSize.sm,
              disabled: _busy || !changed,
              onPressed: _saveDescription,
            ),
          ),
        ],
      ),
      _droppable(
        label: 'Drop to set the banner',
        onImage: _setBanner,
        child: _pictureRow(
          label: 'Banner',
          isSet: bannerSet,
          onChoose: _chooseBanner,
          onRemove: () => _run(
            'remove the banner',
            () => ref.read(apiProvider).deleteSpaceBanner(),
          ),
        ),
      ),
      _droppable(
        label: 'Drop to set the icon',
        onImage: _setIcon,
        child: _pictureRow(
          label: 'Icon',
          isSet: iconSet,
          onChoose: _chooseIcon,
          onRemove: _removeIcon,
        ),
      ),
      if (actionError != null)
        SettingsCardBlock(
          children: [
            AppErrorState(message: actionError!, onDismiss: clearActionError),
          ],
        ),
    ];
  }

  List<Widget> _landingRows(api.SpaceSettings loaded) {
    return [
      SettingsDetailRow(
        icon: AppIcons.preview,
        title: 'Preview',
        trailing: AppButton(
          label: 'Preview as a visitor',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: () => unawaited(_previewAsVisitor(loaded)),
        ),
      ),
      SettingsCardBlock(
        children: [
          // The width the join sheet gives it, so the preview is not larger than the real thing.
          Align(
            alignment: Alignment.centerLeft,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: _card(loaded),
            ),
          ),
        ],
      ),
    ];
  }
}
