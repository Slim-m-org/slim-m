// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The picker's Favorites tab: the caller's saved GIFs and message media as
/// one grid. Tap sends; a wide window reorders by drag, a narrow one through
/// the long-press menu (`desktop-vs-mobile.md`: width decides, never platform).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../widgets/context_menu_region.dart';
import '../../composer/providers/composer_actions.dart';
import '../providers/favorites_controller.dart';
import 'favorite_tile.dart';

class FavoritesGrid extends ConsumerStatefulWidget {
  const FavoritesGrid({super.key, required this.onPicked, this.channelId});

  final ValueChanged<api.Attachment> onPicked;

  /// The channel the media is headed for, so its ATTACH_FILES overwrite counts.
  final String? channelId;

  @override
  ConsumerState<FavoritesGrid> createState() => _FavoritesGridState();
}

class _FavoritesGridState extends ConsumerState<FavoritesGrid> {
  String? _selectingId;
  String? _error;

  Future<void> _pick(api.Favorite favorite) async {
    setState(() {
      _selectingId = favorite.id;
      _error = null;
    });
    try {
      final attachment = await ref
          .read(composerActionsProvider)
          .selectFavorite(favorite.id, channelId: widget.channelId);
      if (!mounted) return;
      widget.onPicked(attachment);
    } on api.ConflictException catch (e, stack) {
      api.AppLog.swallowed(api.LogTag.media, 'Favorite unavailable', e, stack);
      ref.invalidate(favoritesProvider);
      if (!mounted) return;
      setState(() {
        _error = 'That favorite is no longer available.';
        _selectingId = null;
      });
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.media, 'send a favorite', e, stack);
      if (!mounted) return;
      setState(() {
        _error = describeApiFailure('attach that favorite', e);
        _selectingId = null;
      });
    }
  }

  Future<void> _guard(Future<void> Function() action, String doing) async {
    try {
      await action();
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.media, doing, e, stack);
      if (mounted) setState(() => _error = describeApiFailure(doing, e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final favorites = ref.watch(favoritesProvider);
    return favorites.when(
      loading: () => const Center(
        child: Padding(
          padding: EdgeInsets.all(AppSpacing.s24),
          child: AppSpinner(size: AppSpinnerSize.lg),
        ),
      ),
      error: (error, _) => AppErrorState(
        message: error is api.ApiException
            ? describeApiFailure('load your favorites', error)
            : 'Could not load your favorites.',
        onRetry: () => ref.invalidate(favoritesProvider),
      ),
      data: (items) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            AppErrorState(
              message: _error!,
              onDismiss: () => setState(() => _error = null),
            ),
            const SizedBox(height: AppSpacing.s8),
          ],
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s24),
              child: Text(
                'No favorites yet.',
                textAlign: TextAlign.center,
                style: AppText.body.copyWith(color: tokens.textSecondary),
              ),
            )
          else
            Flexible(child: _grid(items)),
        ],
      ),
    );
  }

  Widget _grid(List<api.Favorite> items) {
    final controller = ref.read(favoritesProvider.notifier);
    final touch = AppTouchTargets.of(context);
    return GridView.builder(
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        crossAxisSpacing: AppSpacing.s8,
        mainAxisSpacing: AppSpacing.s8,
        childAspectRatio: 1.3,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final favorite = items[index];
        final tile = FavoriteTile(
          key: ValueKey('favorite-${favorite.id}'),
          favorite: favorite,
          busy: _selectingId != null,
          selecting: _selectingId == favorite.id,
          onTap: () => unawaited(_pick(favorite)),
        );
        return ContextMenuRegion(
          itemsBuilder: (context, close) => [
            if (index > 0)
              AppMenuItem(
                label: touch ? 'Move earlier' : 'Move to front',
                leading: AppIcons.moveUp,
                onTap: () {
                  close();
                  unawaited(
                    _guard(
                      () => controller.move(index, touch ? index - 1 : 0),
                      'reorder your favorites',
                    ),
                  );
                },
              ),
            if (touch && index < items.length - 1)
              AppMenuItem(
                label: 'Move later',
                leading: AppIcons.moveDown,
                onTap: () {
                  close();
                  unawaited(
                    _guard(
                      () => controller.move(index, index + 1),
                      'reorder your favorites',
                    ),
                  );
                },
              ),
            AppMenuItem(
              label: 'Remove from favorites',
              leading: AppIcons.delete,
              tone: AppMenuItemTone.danger,
              onTap: () {
                close();
                unawaited(
                  _guard(
                    () => controller.remove(favorite.id),
                    'remove that favorite',
                  ),
                );
              },
            ),
          ],
          child: touch
              ? tile
              : _Reorderable(
                  index: index,
                  onMove: (from) => unawaited(
                    _guard(
                      () => controller.move(from, index),
                      'reorder your favorites',
                    ),
                  ),
                  child: tile,
                ),
        );
      },
    );
  }
}

/// A tile that can be dragged onto another to take its place.
class _Reorderable extends StatelessWidget {
  const _Reorderable({
    required this.index,
    required this.onMove,
    required this.child,
  });

  final int index;
  final ValueChanged<int> onMove;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DragTarget<int>(
      onWillAcceptWithDetails: (details) => details.data != index,
      onAcceptWithDetails: (details) => onMove(details.data),
      builder: (context, candidates, _) => Draggable<int>(
        data: index,
        feedback: const SizedBox.shrink(),
        childWhenDragging: Opacity(opacity: 0.4, child: child),
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: candidates.isEmpty
                ? null
                : Border.all(
                    color: Theme.of(context).extension<AppTokens>()!.focusRing,
                    width: focusRingWidth,
                  ),
          ),
          child: child,
        ),
      ),
    );
  }
}
