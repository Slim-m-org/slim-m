// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Profile's "Identity" card: picture, display name and username.
///
/// Change opens `showAvatarPhotoMenu`: take, choose, browse, remove. Choose
/// and browse stay two rows because a Photos-only pick cannot reach a picture
/// that arrived by download or AirDrop. See `attachment_picker.dart`.
library;

import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiUsers, LogTag, reportFailure;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../messages/widgets/attachment_picker.dart';
import '../../messages/widgets/image_drop_zone.dart';
import '../../messages/widgets/image_downscale.dart'
    show canDecodeImage, unreadableImageMessage;
import 'avatar_crop_sheet.dart';
import 'avatar_photo_menu.dart';
import 'banner_settings_row.dart';
import 'identity_row.dart';
import 'edit_display_name_sheet.dart';
import '../../../widgets/run_guarded.dart';
import '../../settings/widgets/settings_section_header.dart';
import 'user_avatar.dart';

const double _avatarSize = AppAvatarSize.s40;

class AvatarSettingsSection extends ConsumerStatefulWidget {
  const AvatarSettingsSection({super.key});

  @override
  ConsumerState<AvatarSettingsSection> createState() =>
      _AvatarSettingsSectionState();
}

class _AvatarSettingsSectionState extends ConsumerState<AvatarSettingsSection>
    with GuardedActionState<AvatarSettingsSection> {
  bool _busy = false;

  /// Fires the same tick every other tappable in this system does, since a
  /// plain [InkWell] carries none of that on its own.
  void _onTapChange(bool hasAvatar) {
    AppHaptics.selection();
    unawaited(_openMenu(hasAvatar));
  }

  Future<void> _openMenu(bool hasAvatar) async {
    final action = await showAvatarPhotoMenu(
      context,
      canTake: ref.read(avatarCameraCaptureProvider) != null,
      canRemove: hasAvatar,
    );
    if (action == null || !mounted) return;
    // Cleared up front, same precedent as composer.dart's own _pickAttachment: a retry must not keep showing an earlier failure.
    clearActionError();
    switch (action) {
      case AvatarPhotoAction.remove:
        await _remove();
      case AvatarPhotoAction.take:
        await _take();
      case AvatarPhotoAction.choose:
        await _pickFile(AttachmentSource.photoLibrary);
      case AvatarPhotoAction.browse:
        await _pickFile(AttachmentSource.stillImageFiles);
    }
  }

  Future<void> _take() async {
    final Uint8List? shot;
    try {
      shot = await ref.read(avatarCameraCaptureProvider)!();
    } catch (e, stack) {
      reportFailure(LogTag.media, 'take an avatar photo', e, stack);
      setActionError('Could not open the camera.');
      return;
    }
    await _crop(shot);
  }

  Future<void> _pickFile(AttachmentSource source) async {
    final PlatformFile? file;
    try {
      file = await ref.read(attachmentPickerProvider(source))();
    } catch (e, stack) {
      reportFailure(LogTag.media, 'pick an avatar file', e, stack);
      setActionError('Could not open the file picker.');
      return;
    }
    if (file == null) return;
    final Uint8List bytes;
    try {
      // readAsBytes streams from disk, since eager loading OOMs on a large pick.
      bytes = await file.readAsBytes();
    } catch (e, stack) {
      reportFailure(LogTag.media, 'read an avatar file', e, stack);
      setActionError('Could not open that photo.');
      return;
    }
    await _crop(bytes);
  }

  Future<void> _crop(Uint8List? picked) async {
    if (picked == null || !mounted) return;
    if (!await canDecodeImage(picked)) {
      setActionError(unreadableImageMessage);
      return;
    }
    if (!mounted) return;

    // Cropped before upload, not after: the server caps an avatar at 2 MB and
    // a phone photo is routinely past that, so the raw pick simply failed.
    final bytes = await showAvatarCropSheet(context, picked);
    if (bytes == null || !mounted) return;

    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'upload the avatar',
      action: () => ref.read(apiProvider).uploadAvatar(bytes),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(meProvider);
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    final ok = await guard(
      whatFailed: 'remove the avatar',
      action: () => ref.read(apiProvider).deleteAvatar(),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) ref.invalidate(meProvider);
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider).valueOrNull;
    final hasAvatar = me?.avatarUpdatedAt != null;
    final enabled = me != null && !_busy;

    return ImageDropZone(
      enabled: enabled,
      label: 'Drop to set your picture',
      onImage: (bytes, _) => unawaited(_crop(bytes)),
      onRejected: setActionError,
      child: SettingsSectionCard(
        title: 'Identity',
        topGap: kDenseSectionTopGap,
        children: [
          IdentityRow(
            leading: ExcludeSemantics(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  UserAvatar(
                    userId: me?.id,
                    name: me?.displayName ?? '',
                    size: _avatarSize,
                  ),
                  if (_busy) const AppSpinner(size: AppSpinnerSize.md),
                ],
              ),
            ),
            title: 'Picture',
            caption: 'Square images work best.',
            trailing: [
              AppButton(
                label: 'Change',
                semanticLabel: 'Change profile picture',
                onPressed: enabled ? () => _onTapChange(hasAvatar) : null,
              ),
            ],
          ),
          const BannerSettingsRow(),
          IdentityRow(
            caption: 'Display name',
            title: me?.displayName ?? '',
            trailing: [
              AppButton(
                label: 'Edit',
                semanticLabel: 'Edit display name',
                onPressed: me == null
                    ? null
                    : () => unawaited(
                        showEditDisplayNameSheet(context, me.displayName),
                      ),
              ),
            ],
          ),
          IdentityRow(
            caption: 'Username',
            title: me == null ? '' : '@${me.username}',
            mono: true,
            trailing: [
              AppIconButton(
                icon: AppIcons.copy,
                semanticLabel: 'Copy username',
                tooltip: 'Copy username',
                iconSize: AppSizes.icon16,
                onPressed: me == null
                    ? null
                    : () => unawaited(
                        Clipboard.setData(
                          ClipboardData(text: '@${me.username}'),
                        ),
                      ),
              ),
            ],
          ),
          if (actionError != null)
            SettingsCardBlock(
              children: [
                AppErrorState(
                  message: actionError!,
                  onDismiss: clearActionError,
                ),
              ],
            ),
        ],
      ),
    );
  }
}
