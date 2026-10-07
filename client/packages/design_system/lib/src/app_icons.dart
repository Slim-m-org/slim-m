// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The icon vocabulary.
///
/// Widgets reference these names, never an icon package directly, so the set can
/// be swapped in one file. Emoji are never interface chrome; they are user
/// content only (reactions), which a CI grep enforces.
library;

import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

abstract final class AppIcons {
  // Navigation and structure.
  static const IconData hash = LucideIcons.hash300;
  static const IconData voice = LucideIcons.volume2300;
  static const IconData settings = LucideIcons.settings300;
  static const IconData members = LucideIcons.users300;

  /// A rail row or header for a channel `@everyone` cannot view, in place of
  /// [hash]/[voice]. Shares its glyph with [permissions] and [tileLocked] -
  /// all three read as "restricted" - but is named for this call site so a
  /// reader never has to guess whether the choice was deliberate.
  static const IconData restrictedChannel = LucideIcons.lock300;

  /// A performance settings pane: personal image cache and preview quality,
  /// or Space retention, canvas and screen-share capacity - the
  /// memory-and-speed dials either way. A gauge, distinct from [settings]'s
  /// gear.
  static const IconData performance = LucideIcons.gauge300;

  /// The operator storage view: disk usage and sweep health. Distinct from
  /// [performance]'s gauge - this is what is on disk, not how fast it runs.
  static const IconData storage = LucideIcons.hardDrive300;

  /// The server metrics screen: request latency and volume over time,
  /// distinct from [performance]'s static capacity dials and [analytics]'s
  /// usage counts - a pulse line reads as "traffic happening" rather than a
  /// fixed setting or a tally.
  static const IconData requestLatency = LucideIcons.activity300;

  static const IconData back = LucideIcons.arrowLeft300;
  static const IconData add = LucideIcons.plus300;
  static const IconData search = LucideIcons.search300;
  static const IconData info = LucideIcons.info300;
  static const IconData chevronDown = LucideIcons.chevronDown300;
  static const IconData chevronUp = LucideIcons.chevronUp300;
  static const IconData pin = LucideIcons.pin300;

  /// Keeping a message in your own private list, distinct from [pin],
  /// which is a moderator putting one at the top of a channel for everyone.
  static const IconData bookmark = LucideIcons.bookmark300;

  /// The trigger for a per-row overflow menu (a channel's manage sheet).
  static const IconData moreVertical = LucideIcons.moreVertical300;

  /// The trigger for an overflow menu sitting in a horizontal run of controls.
  static const IconData moreHorizontal = LucideIcons.moreHorizontal300;

  /// A dedicated grab zone for a row whose primary control is an editable
  /// text field: unlike a channel row's held-press drag, wrapping the whole
  /// row here would contest the field's own long-press text selection for
  /// the same gesture, so this needs its own glyph rather than reusing that
  /// pattern.
  static const IconData dragHandle = LucideIcons.gripVertical300;

  /// A menu's own reorder pair, for a list too short-lived a drag to be
  /// worth building (the rail's per-category menu): moves one step, not a
  /// destination picker.
  static const IconData moveUp = LucideIcons.arrowUp300;
  static const IconData moveDown = LucideIcons.arrowDown300;

  /// Folding a category's channels out of the way, and the reverse.
  static const IconData fold = LucideIcons.foldVertical300;
  static const IconData unfold = LucideIcons.unfoldVertical300;

  // Messaging.
  static const IconData send = LucideIcons.send300;
  static const IconData reply = LucideIcons.reply300;
  static const IconData forward = LucideIcons.forward300;
  static const IconData thread = LucideIcons.messagesSquare300;
  static const IconData edit = LucideIcons.pencil300;
  static const IconData retry = LucideIcons.rotateCw300;
  static const IconData pending = LucideIcons.clock300;
  static const IconData failed = LucideIcons.circleAlert300;
  static const IconData poll = LucideIcons.barChart2300;

  /// The poll option strictly ahead of every other, drawn in `textSecondary`
  /// rather than the accent: "this is winning" is not one of the seven
  /// closed accent roles. Never shown for a tie at the top.
  static const IconData pollLeading = LucideIcons.trendingUp300;
  static const IconData code = LucideIcons.code300;
  static const IconData webhook = LucideIcons.webhook300;
  static const IconData smile = LucideIcons.smile300;

  /// The emoji picker's category tabs. `smileysEmotion` reuses [smile] above
  /// and `recent` reuses [clock] below; these eight cover the rest of the
  /// `emojis` package's [EmojiGroup] set.
  static const IconData peopleBody = LucideIcons.footprints300;
  static const IconData animalsNature = LucideIcons.pawPrint300;
  static const IconData foodDrink = LucideIcons.utensils300;
  static const IconData activities = LucideIcons.volleyball300;
  static const IconData travelPlaces = LucideIcons.planeTakeoff300;
  static const IconData objects = LucideIcons.lightbulb300;
  static const IconData symbols = LucideIcons.asterisk300;
  static const IconData flags = LucideIcons.flag300;

  /// The picker's tab for the deployment's own uploaded emoji, and the
  /// placeholder a tile falls back to when that image cannot be fetched.
  static const IconData customEmoji = LucideIcons.sticker300;
  static const IconData imageMissing = LucideIcons.imageOff300;

  /// A picked image, once there is one to replace rather than choose fresh.
  static const IconData image = LucideIcons.image300;

  /// Overlaid on a held gif or a not-yet-loaded media preview: tap to reveal.
  static const IconData play = LucideIcons.play300;

  /// Running a fenced code block through an installed module's
  /// `code-block-runner` extension point (docs/decisions/0021). Shares
  /// [play]'s glyph but named separately: the two are different actions and
  /// must be free to diverge later.
  static const IconData runCode = LucideIcons.play300;

  /// A playing attachment video's own transport control, distinct from
  /// [play]'s poster-overlay role.
  static const IconData pause = LucideIcons.pause300;

  /// The document-browser route onto an attachment, distinct from [image]'s
  /// Photos-backed one; see `attachment_picker.dart`.
  static const IconData attachFile = LucideIcons.paperclip300;

  /// The composer's mobile "Paste image" action; see
  /// `composer_clipboard_paste.dart`.
  static const IconData clipboardPaste = LucideIcons.clipboardPaste300;

  /// Picking a `.zip` for bulk emoji import; see `emoji_bulk_upload_card.dart`.
  static const IconData fileArchive = LucideIcons.fileArchive300;

  /// The GIF picker; see `gif_picker.dart`. Distinct from [image], which
  /// opens a device's own photo library rather than a search.
  static const IconData gif = LucideIcons.clapperboard300;

  /// Saving an attachment this app cannot render inline - a PDF, an archive,
  /// or a video before it finishes buffering. See `attachment_save.dart`.
  static const IconData download = LucideIcons.download300;

  /// Handing an opened image to the system share sheet; see `image_export.dart`.
  static const IconData share = LucideIcons.share2300;

  /// A staleness cue distinct from [pending]: the same glyph, a different
  /// role (an expiring device or invite rather than an in-flight send), kept
  /// as its own name so the two are never conflated at a call site.
  static const IconData clock = LucideIcons.clock300;

  // Calls and canvas, wired up in later phases.
  static const IconData mic = LucideIcons.mic300;
  static const IconData micOff = LucideIcons.micOff300;
  static const IconData headphones = LucideIcons.headphones300;

  /// What a member's activity line shows, by kind: listening to something, or
  /// playing a game. Presence copy, never a status dot.
  static const IconData listening = LucideIcons.headphones300;
  static const IconData playing = LucideIcons.gamepad2300;

  /// Hearing one person, and not hearing them. Distinct from [mic]/[micOff],
  /// which are about your own microphone: these two are about what reaches
  /// your ears, so a call site that confuses them says the opposite thing.
  static const IconData speaker = LucideIcons.volume2300;
  static const IconData speakerOff = LucideIcons.volumeX300;
  static const IconData camera = LucideIcons.video300;
  static const IconData cameraOff = LucideIcons.videoOff300;

  /// Flipping between front/back on mobile, or picking a webcam on desktop.
  static const IconData switchCamera = LucideIcons.switchCamera300;
  static const IconData screenShare = LucideIcons.monitorUp300;
  static const IconData screenShareStop = LucideIcons.monitorOff300;
  static const IconData screenShareSwitch = LucideIcons.monitorCog300;
  static const IconData leaveCall = LucideIcons.phoneOff300;

  /// Expanding a call tile's video to fill the screen.
  static const IconData expand = LucideIcons.maximize2300;

  /// Leaving full screen playback - the shrink counterpart to [expand].
  static const IconData collapse = LucideIcons.shrink300;

  /// Starting or joining a DM call, distinct from [voice] (a voice channel's
  /// own icon) since a DM has no channel kind of its own to draw.
  static const IconData startCall = LucideIcons.phone300;

  /// A call in the transcript that nobody answered. Distinct from
  /// [leaveCall], which is the control you press to hang up: this one is a
  /// record of something that already happened and is never a button.
  static const IconData missedCall = LucideIcons.phoneMissed300;

  /// Making a new channel category, beside [add] (a new channel) in the rail's
  /// own menu, so the two "create" items read as different things at a glance.
  static const IconData addCategory = LucideIcons.folderPlus300;
  static const IconData canvas = LucideIcons.pencilRuler300;

  /// The canvas's own draw/erase toggle. Distinct constants from [edit] even
  /// though [pen] shares its glyph, since one names a message action and the
  /// other a drawing tool - a future change to one must not silently retint
  /// the other.
  static const IconData pen = LucideIcons.pencil300;
  static const IconData eraser = LucideIcons.eraser300;
  static const IconData undo = LucideIcons.undo2300;

  /// The canvas's two other tool-dock tools (decision 0004): a note holds
  /// typed text, and the shape tool's primitives are picked from the overflow
  /// menu while it is active.
  static const IconData note = LucideIcons.stickyNote300;
  static const IconData shapeRectangle = LucideIcons.square300;
  static const IconData shapeEllipse = LucideIcons.circle300;
  static const IconData shapeLine = LucideIcons.minus300;
  static const IconData shapeArrow = LucideIcons.arrowUpRight300;

  /// The canvas's pan tool; a hand, because the four-way arrows read as "move this object".
  static const IconData pan = LucideIcons.hand300;

  /// The canvas's z-order actions, for a selected image overlapping another.
  static const IconData bringToFront = LucideIcons.bringToFront300;
  static const IconData sendToBack = LucideIcons.sendToBack300;

  /// The canvas's text activity log: the accessibility fallback for a
  /// surface a screen reader otherwise cannot read at all.
  static const IconData activityLog = LucideIcons.history300;

  /// Jumps the canvas camera back to the world origin - the one route back
  /// short of closing and reopening the pane, see `worldLimit`'s own doc.
  static const IconData recenter = LucideIcons.locate300;

  /// A camera or screen-share tile on the canvas: locked in place (so a
  /// drawing tool reaches through it) or free to drag and resize. Distinct
  /// from [permissions], which shares [tileLocked]'s glyph for an unrelated
  /// role-based bit.
  static const IconData tileLocked = LucideIcons.lock300;
  static const IconData tileUnlocked = LucideIcons.lockOpen300;

  /// Removing one tile from this viewer's own canvas - distinct from
  /// [micOff]/[cameraOff], which mute a signal rather than remove a tile.
  static const IconData tileHide = LucideIcons.eyeOff300;

  /// A bot's private answer, marked "Only you can see this". Shares its glyph
  /// with [tileHide]: both mean "not shown to everyone".
  static const IconData privateReply = LucideIcons.eyeOff300;

  /// A tile's own resize grip, drawn at its bottom-right corner.
  static const IconData tileResize = LucideIcons.moveDiagonal2300;

  // Account.
  static const IconData signOut = LucideIcons.logOut300;
  static const IconData account = LucideIcons.circleUser300;

  /// The personal space: your own notes, not another person's avatar.
  static const IconData notebook = LucideIcons.notebookPen300;

  /// The personal settings nav: theme and type, and the devices a session
  /// lives on. Distinct from [camera]/[avatarCamera], which are about a
  /// picture rather than a screen.
  static const IconData appearance = LucideIcons.palette300;
  static const IconData devices = LucideIcons.monitorSmartphone300;

  /// One signed-in device, drawn as the kind of thing it is. A list of
  /// sessions is read to spot the one you do not recognise, and three
  /// identical glyphs make every row look the same at a glance.
  static const IconData devicePhone = LucideIcons.smartphone300;
  static const IconData deviceLaptop = LucideIcons.laptop300;
  static const IconData deviceDesktop = LucideIcons.monitor300;

  /// The settings avatar's "tap to change" badge. Distinct from [camera]
  /// above, which is a video camera for call controls; this is a still one.
  static const IconData avatarCamera = LucideIcons.camera300;

  // Notifications.
  static const IconData notificationsOn = LucideIcons.bell300;
  static const IconData notificationsOff = LucideIcons.bellOff300;
  static const IconData mentions = LucideIcons.atSign300;

  /// Marking a conversation unread again: a note to yourself to come back.
  static const IconData unread = LucideIcons.mail300;

  /// Severity and surfaces (callouts, menus, code blocks). Distinct shapes
  /// (circle, triangle, sparkle, octagon) so a tone survives greyscale rather
  /// than resting on colour alone.
  static const IconData warning = LucideIcons.triangleAlert300;
  static const IconData highlight = LucideIcons.sparkles300;
  static const IconData danger = LucideIcons.octagonAlert300;
  static const IconData check = LucideIcons.check300;
  static const IconData chevronRight = LucideIcons.chevronRight300;
  static const IconData copy = LucideIcons.copy300;

  /// Copying a shareable link rather than the raw value beside it -
  /// an invite link carries its server too, where [copy] takes the code alone.
  static const IconData link = LucideIcons.link300;

  /// A fourth, distinct shape for "not known", never to be confused with
  /// [danger]'s "known not to work".
  static const IconData unknown = LucideIcons.circleHelp300;

  // Moderation and administration: the reports queue, invite management,
  // roles, and channel permission overwrites.
  static const IconData chat = LucideIcons.messageSquare300;
  static const IconData report = LucideIcons.messageSquareWarning300;
  static const IconData invite = LucideIcons.mailPlus300;
  static const IconData shield = LucideIcons.shield300;

  /// A server that offers no reporting or blocking. Struck through, so "no
  /// recourse here" reads without colour, the same rule the severity icons
  /// above follow.
  static const IconData shieldOff = LucideIcons.shieldOff300;

  static const IconData delete = LucideIcons.trash2300;
  static const IconData revoke = LucideIcons.ban300;

  /// Undoing a block. Distinct from [revoke]: "Block" and "Unblock" are
  /// opposite actions that used to share [revoke]'s glyph, which drew the
  /// same icon for both ends of the same toggle in one menu.
  static const IconData restoreAccess = LucideIcons.userCheck300;

  /// Issuing a one-time password reset code for a locked-out account. A key
  /// rather than [restoreAccess]: that one undoes a block, this one hands
  /// somebody a credential.
  static const IconData resetCode = LucideIcons.keyRound300;
  static const IconData dismiss = LucideIcons.x300;
  static const IconData permissions = LucideIcons.lock300;

  /// The biometric app lock: Face ID, a fingerprint, Windows Hello, or the
  /// device passcode fallback. A distinct glyph from [permissions] and
  /// [tileLocked], which are both about a canvas tile rather than the app
  /// itself.
  static const IconData appLock = LucideIcons.fingerprint300;

  /// Space usage analytics. A different weight-300 bar-chart glyph from
  /// [poll]'s, so the two rows never share a silhouette in the settings list.
  static const IconData analytics = LucideIcons.barChart3300;

  /// The Dock: the module marketplace. A puzzle piece for "an installable
  /// addon", matching decision 0021's own naming.
  static const IconData dock = LucideIcons.puzzle300;

  /// Removing a row from a personal list view rather than deleting anything:
  /// distinct from [delete], which destroys the thing itself.
  static const IconData removeFromList = LucideIcons.listX300;

  /// Leaving this surface to view something in its own context - the report
  /// queue's "Jump to message", not a link to another site.
  static const IconData jumpToMessage = LucideIcons.externalLink300;

  /// Moves a call's video into its own OS window on desktop.
  static const IconData popOut = LucideIcons.squareArrowOutUpRight300;

  /// A button that opens another site in the browser, as a bot's link button does.
  static const IconData externalLink = LucideIcons.externalLink300;

  /// The custom title bar's own three window controls, decision 0012.
  /// [windowMaximize] shares [expand]'s glyph on purpose - one shape, two
  /// call sites - and [windowRestore] is what the same button becomes once
  /// already maximized, the two-overlapping-squares convention every native
  /// title bar already uses for it.
  static const IconData windowMinimize = LucideIcons.minus300;
  static const IconData windowMaximize = LucideIcons.maximize2300;
  static const IconData windowRestore = LucideIcons.copy300;
  static const IconData windowClose = LucideIcons.x300;

  /// The title bar's own quit item - a real exit reachable with no tray, see
  /// `window_menu_button.dart`'s own doc comment for why it has to exist.
  static const IconData windowQuit = LucideIcons.power300;

  /// Glyphs a bot's call control may name (decision 0045). `play`, `pause` and
  /// the volume pair reuse [play], [pause], [speaker] and [speakerOff].
  static const IconData callStop = LucideIcons.square300;
  static const IconData callSkipNext = LucideIcons.skipForward300;
  static const IconData callSkipPrevious = LucideIcons.skipBack300;
  static const IconData callRepeat = LucideIcons.repeat300;
  static const IconData callShuffle = LucideIcons.shuffle300;
  static const IconData callList = LucideIcons.listMusic300;

  /// Leads every row a bot adds to a menu, so none can borrow a built-in's glyph.
  static const IconData botAction = LucideIcons.bot300;

  /// The fallback for a call control whose icon this client does not know.
  static const IconData callControl = LucideIcons.circleDot300;
}
