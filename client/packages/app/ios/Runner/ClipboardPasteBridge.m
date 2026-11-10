// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
#import "ClipboardPasteBridge.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

/// Swizzles two methods on Flutter's own `FlutterTextInputView`, so the
/// system edit menu's Paste item works for an image, not only a string.
/// Confirmed against the engine source itself
/// (`shell/platform/darwin/ios/framework/Source/FlutterTextInputPlugin.{h,mm}`
/// in the flutter/engine repo) rather than assumed.
///
/// That class ships two lines that are the whole obstacle:
/// `canPerformAction:` answers `[UIPasteboard generalPasteboard].hasStrings`
/// for `paste:` with the comment "Forbid pasting images, memojis, or other
/// non-string content," and `paste:` itself only ever reads
/// `UIPasteboard.generalPasteboard.string`. So an image-only pasteboard never
/// even offers the menu item, and could not use it if it did.
///
/// `FlutterTextInputView` is declared only in a private engine header
/// (`Source/FlutterTextInputPlugin.h`), never the public
/// `Flutter.framework/Headers`, and `FLUTTER_DARWIN_EXPORT` on its symbol is
/// debug-build-only. Neither matters here: an Objective-C class's metadata is
/// registered with the runtime for every loaded image regardless of symbol
/// visibility, which is what makes `NSClassFromString` below reliable in a
/// release build too.
///
/// If a future engine upgrade renames the class or either selector, both
/// lookups below fail and this backs out to a no-op rather than swizzling
/// half of a pair or crashing, so a break here reads as "the old prompt-every-
/// time behaviour is back," not as a crash - diagnosable by grepping the
/// engine source at the two paths named above for what moved.
/// The replacements live on a **donor class of our own**, never in a category
/// on the target.
///
/// Installing this swizzle was never enough on its own: Flutter's default
/// `contextMenuBuilder` on iOS 16+ routes through `SystemContextMenu`, which
/// decided Paste's presence in Dart from `Clipboard.hasStrings()` alone and
/// sent native a fixed item list that bypassed `canPerformAction:` entirely -
/// confirmed on a real device 2026-08-01. `composer_context_menu.dart` closes
/// that on the Dart side by forcing the platform's own Paste item into that
/// list whenever the clipboard holds an image, which is what makes native
/// ask `canPerformAction:` here in the first place. Confirmed working end to
/// end on a real iPhone 2026-08-02: long-press the composer, tap Paste, the
/// image attaches with no prompt. This swizzle needed no change either way -
/// it was always correct, only unreached - and still applies on its own to a
/// non-Material field or an iOS below 16 (`UIMenuController`'s traditional
/// `canPerformAction:`-driven path). See `docs/os_backlog/ios_backlog.md` for
/// the full story across all three attempts.
///
/// A category on `FlutterTextInputView` emits a link-time reference to
/// `_OBJC_CLASS_$_FlutterTextInputView`, and the engine ships that class
/// without exporting the symbol, so the app fails to link with "Undefined
/// symbol". That is not a theoretical concern: it is exactly how the first
/// version of this file broke the 0.21.2 iOS build, while every Dart test
/// passed. Resolving the class by name at runtime is pointless if the
/// compiler has already been told it exists at link time, and a category is
/// that assertion.
@interface SlimmPasteDonor : UIResponder
- (BOOL)slimm_canPerformAction:(SEL)action withSender:(id)sender;
- (void)slimm_paste:(id)sender;
@end

static void (^sOnImage)(NSData *pngData);

@implementation SlimmPasteDonor

- (BOOL)slimm_canPerformAction:(SEL)action withSender:(id)sender {
  // `hasImages` is UIPasteboard's own metadata check, one of the reads Apple
  // documents as exempt from the "Allow Paste?" consent prompt.
  if (action == @selector(paste:) && [UIPasteboard generalPasteboard].hasImages) {
    return YES;
  }
  // After the swap this calls the ORIGINAL implementation (see the exchange
  // below): every other action, and a paste with no image, are unaffected.
  return [self slimm_canPerformAction:action withSender:sender];
}

- (void)slimm_paste:(id)sender {
  UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
  // Text wins if both are present, matching the platform's own default.
  if (pasteboard.string == nil && pasteboard.hasImages) {
    // iOS itself dispatched this `paste:` call, so this read of the
    // pasteboard's actual value - the kind that would otherwise raise the
    // consent prompt - is exempt: it happens inside that same dispatch,
    // never as a later, separate read triggered from Dart. Only the PNG
    // encode of a full-resolution photo moves off the main thread.
    UIImage *image = pasteboard.image;
    if (image != nil && sOnImage != nil) {
      void (^onImage)(NSData *) = sOnImage;
      dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *pngData = UIImagePNGRepresentation(image);
        if (pngData == nil) return;
        dispatch_async(dispatch_get_main_queue(), ^{
          onImage(pngData);
        });
      });
      return;
    }
  }
  // Original implementation; unaffected text-paste behaviour.
  [self slimm_paste:sender];
}

@end

BOOL SlimmInstallClipboardPasteBridge(void (^onImage)(NSData *pngData)) {
  sOnImage = [onImage copy];
  Class cls = NSClassFromString(@"FlutterTextInputView");
  if (cls == Nil) {
    NSLog(@"[slimm] ClipboardPasteBridge: FlutterTextInputView not found; "
          @"image paste via the edit menu is disabled for this build.");
    return NO;
  }
  // Resolved up front and only exchanged if every lookup succeeds, so a
  // missing selector never leaves one half of the pair swizzled and the
  // other not.
  // The replacements are read off the donor and grafted onto the target,
  // which is what keeps the target out of the link table entirely.
  Method donorCanPerform =
      class_getInstanceMethod([SlimmPasteDonor class], @selector(slimm_canPerformAction:withSender:));
  Method donorPaste = class_getInstanceMethod([SlimmPasteDonor class], @selector(slimm_paste:));
  if (donorCanPerform == NULL || donorPaste == NULL) {
    NSLog(@"[slimm] ClipboardPasteBridge: donor methods missing; image paste "
          @"via the edit menu is disabled for this build.");
    return NO;
  }
  class_addMethod(cls, @selector(slimm_canPerformAction:withSender:),
                  method_getImplementation(donorCanPerform),
                  method_getTypeEncoding(donorCanPerform));
  class_addMethod(cls, @selector(slimm_paste:), method_getImplementation(donorPaste),
                  method_getTypeEncoding(donorPaste));

  Method originalCanPerform = class_getInstanceMethod(cls, @selector(canPerformAction:withSender:));
  Method swizzledCanPerform =
      class_getInstanceMethod(cls, @selector(slimm_canPerformAction:withSender:));
  Method originalPaste = class_getInstanceMethod(cls, @selector(paste:));
  Method swizzledPaste = class_getInstanceMethod(cls, @selector(slimm_paste:));
  if (originalCanPerform == NULL || swizzledCanPerform == NULL || originalPaste == NULL ||
      swizzledPaste == NULL) {
    NSLog(@"[slimm] ClipboardPasteBridge: canPerformAction: or paste: missing "
          @"on FlutterTextInputView; image paste via the edit menu is disabled "
          @"for this build.");
    return NO;
  }
  method_exchangeImplementations(originalCanPerform, swizzledCanPerform);
  method_exchangeImplementations(originalPaste, swizzledPaste);
  return YES;
}
