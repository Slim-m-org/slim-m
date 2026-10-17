// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tapped image, opened over the app: pinch to zoom, drag to pan, and
/// either a swipe down or the close control to leave.
///
/// A message can carry several images, and tapping one used to open exactly
/// that one with no way to reach its siblings. The viewer is a gallery now:
/// the whole message's images page left and right, the header says which of
/// how many, and the arrow keys work where there is a keyboard. Each page is
/// a [FullscreenImagePage]; this file owns the backdrop, the header and the
/// paging.
///
/// The tapped image is handed its bytes rather than an id, so it cannot start
/// a second fetch: the only way in is a tap on an image already showing those
/// exact bytes, and passing them down is what makes "still loading" and "a
/// fetch failed" unreachable states for that page. Its siblings have no such
/// guarantee - nothing has fetched them - so they load through
/// `attachmentBytesProvider` and do render those two states. That asymmetry is
/// deliberate: the page the reader tapped must never flash a spinner.
///
/// A decode failure is reachable on the tapped page too: `AttachmentView`'s
/// own inline thumbnail offers this route as its only tap target even once its
/// bytes have already failed to decode there, so the same bytes are tried
/// again here rather than assuming they will now succeed -
/// [FullscreenDecodeFailure] is what stops that retry from surfacing as an
/// uncaught exception.
///
/// A `Hero` flight carries the tapped image from its thumbnail into this
/// viewer, and only that page takes the tag: a sibling has no thumbnail this
/// route flew from, and two pages sharing one tag would throw. The tag choice
/// is the whole trick: an attachment is
/// content-addressed, so one id legitimately rides on more than one message
/// (`models_attachments.dart`), and two rows showing the same image with one
/// shared id-based tag would throw the moment a flight starts. Each
/// `AttachmentView` therefore mints its own identity `Object` as the tag and
/// hands the same object here, so tags are unique per mounted thumbnail by
/// construction. Callers with no thumbnail to fly from pass no tag and keep
/// the plain fade.
///
/// The backdrop is black in both themes: a surface token would tint the
/// letterbox around a photo, and the controls are themed dark to match rather
/// than following the app's brightness.
///
/// This route is pushed on the root navigator, above any Scaffold, so
/// nothing upstream supplies the [Material] ancestor [Text] and [Icon] rely
/// on for their default style; without one Flutter renders them in its own
/// debug fallback (red text, a double yellow underline) rather than the
/// theme's, which reads as a colour bug and is not one. `build` below wraps
/// its content in a transparent [Material] for exactly this reason.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/attachment_bytes.dart';
import 'fullscreen_image_actions.dart';
import 'fullscreen_image_page.dart';
import 'image_actions_menu.dart';
import 'message_row_parts.dart';

/// How large the floating viewer is allowed to get on a desktop window.
const double kViewerMaxWidth = 1100;
const double kViewerMaxHeight = 820;

/// Opens [images] fullscreen at [index], with that page's [bytes] already in
/// hand. Non-opaque so the conversation behind stays visible through the fade
/// rather than the route cutting to black.
Future<void> showFullscreenImage(
  BuildContext context, {
  required List<api.Attachment> images,
  required int index,
  required Uint8List bytes,
  Object? heroTag,
}) {
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: AppMotion.reduced(
        context,
        const Duration(milliseconds: 160),
      ),
      reverseTransitionDuration: AppMotion.reduced(
        context,
        const Duration(milliseconds: 120),
      ),
      pageBuilder: (_, animation, _) => FadeTransition(
        opacity: animation,
        child: FullscreenImageViewer(
          images: images,
          index: index,
          bytes: bytes,
          heroTag: heroTag,
        ),
      ),
    ),
  );
}

class FullscreenImageViewer extends ConsumerStatefulWidget {
  const FullscreenImageViewer({
    super.key,
    required this.images,
    required this.index,
    required this.bytes,
    this.heroTag,
  });

  /// Every image on the message, in the order the message shows them.
  final List<api.Attachment> images;

  /// Which of [images] was tapped, and so which page opens first and which
  /// one [bytes] belongs to.
  final int index;

  /// The tapped image's bytes, already fetched by the row that opened this.
  final Uint8List bytes;

  /// The tapped thumbnail's own identity tag, or null for a caller with no
  /// thumbnail to fly from; see the library doc for why never a shared id.
  final Object? heroTag;

  @override
  ConsumerState<FullscreenImageViewer> createState() =>
      _FullscreenImageViewerState();
}

class _FullscreenImageViewerState extends ConsumerState<FullscreenImageViewer> {
  late final PageController _pages = PageController(initialPage: widget.index);
  late int _current = widget.index;
  bool _zoomed = false;
  String? _exportFailure;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _pages.dispose();
    super.dispose();
  }

  void _close() {
    Navigator.of(context).maybePop();
  }

  void _step(int by) {
    final target = _current + by;
    if (target < 0 || target >= widget.images.length) return;
    final duration = AppMotion.reduced(
      context,
      const Duration(milliseconds: 180),
    );
    // A zero-length animateToPage never moves the page; reduced motion jumps.
    if (duration == Duration.zero) {
      _pages.jumpToPage(target);
      return;
    }
    _pages.animateToPage(
      target,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  /// Arrows page and Escape closes, for a desktop window with no swipe.
  ///
  /// A hardware handler rather than a focus node's `onKeyEvent`: on web the
  /// browser moves focus to the semantics layer once the route is open, and a
  /// key then never reaches the viewer's own node.
  bool _onKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;
    // A dialog opened over the viewer owns the keyboard until it closes.
    if (ModalRoute.of(context)?.isCurrent != true) return false;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      _close();
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _step(1);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _step(-1);
    } else {
      return false;
    }
    return true;
  }

  /// One page. The tapped image already has its bytes and must never flash a
  /// spinner; a sibling has never been fetched, so it shows the two states the
  /// tapped page cannot reach.
  Widget _page(int index) {
    final image = widget.images[index];
    if (index == widget.index) {
      return FullscreenImagePage(
        filename: image.filename,
        bytes: widget.bytes,
        heroTag: widget.heroTag,
        onDismiss: _close,
        onZoomChanged: _onZoomChanged,
      );
    }
    return ref
        .watch(attachmentBytesProvider(image.id))
        .when(
          loading: () => const Center(child: AttachmentPlaceholder()),
          error: (_, _) => FullscreenLoadFailure(
            filename: image.filename,
            onRetry: () => ref.invalidate(attachmentBytesProvider(image.id)),
          ),
          data: (bytes) => FullscreenImagePage(
            filename: image.filename,
            bytes: bytes,
            onDismiss: _close,
            onZoomChanged: _onZoomChanged,
          ),
        );
  }

  Future<Uint8List> _currentBytes() {
    if (_current == widget.index) return Future.value(widget.bytes);
    return ref.read(attachmentBytesProvider(widget.images[_current].id).future);
  }

  void _onZoomChanged(bool zoomed) => setState(() => _zoomed = zoomed);

  @override
  Widget build(BuildContext context) {
    // A phone gives the image the whole window, which is the point of opening
    // it. A desktop window has room to keep the app visible around it, so the
    // image floats in a panel and a click beside it puts the image away.
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    return Theme(
      data: buildTheme(Brightness.dark, AppTokens.dark),
      // Material ancestor for Text/Icon; see this file's library doc.
      child: Material(
        type: MaterialType.transparency,
        child: _Backdrop(
          compact: compact,
          onDismiss: _close,
          child: SafeArea(
            child: Focus(
              autofocus: true,
              child: Column(
                children: [
                  _ViewerHeader(
                    filename: widget.images[_current].filename,
                    counter: widget.images.length > 1
                        ? '${_current + 1} of ${widget.images.length}'
                        : null,
                    onClose: _close,
                    actions: ImageExportActions(
                      key: ValueKey(widget.images[_current].id),
                      image: widget.images[_current],
                      loadBytes: _currentBytes,
                      onFailure: (message) =>
                          setState(() => _exportFailure = message),
                    ),
                  ),
                  if (_exportFailure case final message?)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.s12,
                      ),
                      child: AppErrorState(
                        message: message,
                        onDismiss: () => setState(() => _exportFailure = null),
                      ),
                    ),
                  Expanded(
                    child: ImageActionsMenuRegion(
                      image: widget.images[_current],
                      loadBytes: _currentBytes,
                      onFailure: (message) =>
                          setState(() => _exportFailure = message),
                      child: PageView.builder(
                        controller: _pages,
                        // Zoomed in, a horizontal drag is a pan across this image, never a turn to the next one.
                        physics: _zoomed
                            ? const NeverScrollableScrollPhysics()
                            : null,
                        itemCount: widget.images.length,
                        onPageChanged: (index) => setState(() {
                          _current = index;
                          _exportFailure = null;
                        }),
                        itemBuilder: (_, index) => _page(index),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewerHeader extends StatelessWidget {
  const _ViewerHeader({
    required this.filename,
    required this.counter,
    required this.onClose,
    required this.actions,
  });

  final String filename;

  /// Share and Save for the image on screen, left of the close control.
  final Widget actions;

  /// "2 of 5", or null when the message carries only this one image and there
  /// is nothing to count.
  final String? counter;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s4,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.ui.copyWith(color: tokens.textSecondary),
            ),
          ),
          if (counter case final counter?)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
              child: Text(
                counter,
                style: AppText.label.copyWith(color: tokens.textSecondary),
              ),
            ),
          actions,
          AppIconButton(
            icon: AppIcons.dismiss,
            semanticLabel: 'Close image',
            size: AppIconButtonSize.touch,
            touch: true,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

/// The dark field the image sits on, and what a click on it means.
///
/// On a phone it is the window and a click on it does nothing, because there
/// is no "outside" to click: the drag gesture is how the image is dismissed.
/// On a desktop window it is a scrim around a floating panel, and clicking it
/// closes the viewer the way clicking beside any modal does.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.compact,
    required this.onDismiss,
    required this.child,
  });

  final bool compact;
  final VoidCallback onDismiss;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    if (compact) {
      return ColoredBox(
        color: Colors.black.withValues(alpha: 0.94),
        child: child,
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onDismiss,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.72)),
          ),
        ),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: kViewerMaxWidth,
              maxHeight: kViewerMaxHeight,
            ),
            // Swallows the taps that land on the panel, so only a click that
            // reaches the scrim behind it counts as clicking outside.
            child: GestureDetector(
              onTap: () {},
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.card),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.94),
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: BorderRadius.circular(AppRadii.card),
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
