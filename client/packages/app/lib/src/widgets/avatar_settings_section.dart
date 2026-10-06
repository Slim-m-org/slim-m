// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings' profile card: the caller's own picture, which is itself the
/// control (a camera badge is the cue), the display name beside its own
/// rename affordance, and the `@handle` underneath.
///
/// Tapping the picture opens `showAvatarPhotoMenu`: take, choose, browse,
/// remove. Choose and browse stay two rows because a Photos-only pick cannot
/// reach a picture that arrived by download or AirDrop. See
/// `attachment_picker.dart`.
///
/// The name and handle used to sit above the settings nav, outside every
/// named section - editable, yet nowhere a caller would think to look for
/// "rename yourself". They live in this card now, which is the whole of the
/// `Profile` pane, so renaming sits beside the picture it is next to on
/// every other profile in this app. The card carries no title of its own:
/// `Profile` under `Profile` would restate the nav row it already sits
/// under, the case decision 0013 made `SettingsSectionCard.title` nullable
/// for.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiUsers;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import 'attachment_picker.dart';
import 'avatar_crop_sheet.dart';
import 'avatar_photo_menu.dart';
import 'edit_display_name_sheet.dart';
import 'run_guarded.dart';
import 'settings_section_header.dart';
import 'user_avatar.dart';

/// Large enough on its own to clear the 44pt touch minimum, so the badge
/// never needs a separately expanded hit target the way a small icon button
/// would.
const double _avatarSize = AppAvatarSize.s56;
const double _badgeSize = 28;

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
        await _crop(await ref.read(avatarCameraCaptureProvider)!());
      case AvatarPhotoAction.choose:
        await _pickFile(AttachmentSource.photoLibrary);
      case AvatarPhotoAction.browse:
        await _pickFile(AttachmentSource.fileBrowser);
    }
  }

  Future<void> _pickFile(AttachmentSource source) async {
    final PlatformFile? file;
    try {
      file = await ref.read(attachmentPickerProvider(source))();
    } catch (e) {
      setActionError('Could not open the file picker.');
      return;
    }
    if (file == null) return;
    // readAsBytes streams from disk, since eager loading OOMs on a large pick.
    await _crop(await file.readAsBytes());
  }

  Future<void> _crop(Uint8List? picked) async {
    if (picked == null || !mounted) return;

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
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final me = ref.watch(meProvider).valueOrNull;
    final hasAvatar = me?.avatarUpdatedAt != null;
    final enabled = me != null && !_busy;

    return SettingsSectionCard(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Semantics(
                    button: true,
                    enabled: enabled,
                    label: 'Change profile picture',
                    child: AppFocusRing(
                      radius: _avatarSize / 2,
                      builder: (context, onFocusChange) => InkWell(
                        onTap: enabled ? () => _onTapChange(hasAvatar) : null,
                        // AppFocusRing replaces this overlay; see its own doc comment.
                        focusColor: Colors.transparent,
                        onFocusChange: onFocusChange,
                        customBorder: const CircleBorder(),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            ExcludeSemantics(
                              child: UserAvatar(
                                userId: me?.id,
                                name: me?.displayName ?? '',
                                size: _avatarSize,
                              ),
                            ),
                            if (_busy)
                              Positioned.fill(
                                child: ExcludeSemantics(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: tokens.surfaceBase.withValues(
                                        alpha: 0.6,
                                      ),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: ExcludeSemantics(
                                child: Container(
                                  width: _badgeSize,
                                  height: _badgeSize,
                                  decoration: BoxDecoration(
                                    color: tokens.accentFill,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: tokens.surfaceBase,
                                      width: 2,
                                    ),
                                  ),
                                  child: Icon(
                                    AppIcons.avatarCamera,
                                    size: AppSizes.icon16,
                                    color: tokens.accentOn,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (me != null) ...[
                    const SizedBox(width: AppSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  me.displayName,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.ui.copyWith(
                                    color: tokens.textPrimary,
                                    fontWeight: AppWeights.medium,
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.s4),
                              AppIconButton(
                                icon: AppIcons.edit,
                                semanticLabel: 'Edit display name',
                                tooltip: 'Edit display name',
                                size: AppIconButtonSize.sm,
                                onPressed: () => unawaited(
                                  showEditDisplayNameSheet(
                                    context,
                                    me.displayName,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Text(
                            '@${me.username}',
                            overflow: TextOverflow.ellipsis,
                            style: AppText.caption.copyWith(
                              color: tokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ] else
                    const Spacer(),
                ],
              ),
              if (actionError != null) ...[
                const SizedBox(height: AppSpacing.s8),
                AppErrorState(
                  message: actionError!,
                  onDismiss: clearActionError,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
