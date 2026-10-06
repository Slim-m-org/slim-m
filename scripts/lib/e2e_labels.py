# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""The accessible names this harness drives the app by.

Kept in one place because they are a contract with the UI, not incidental
strings: when a label changes, exactly one line here changes with it, and a
scenario that no longer matches says so rather than timing out on a name
nobody remembered was duplicated across three files.
"""

# Not the hint text: it vanishes once typed, and goes bare for a thread/DM, once colliding with "Pinned/Search messages".
COMPOSER = "Message composer"
SEND = "Send message"
ATTACH = "Attach a file"
ADD_REACTION = "Add reaction"
REMOVE_ATTACHMENT = "Remove attachment"

# Rail and navigation
SPACE_MENU = "Space menu"
SPACE_SETTINGS = "Space settings"
PERSONAL_SETTINGS = "Personal settings"

# Personal settings. Nav entries first: a control needs its own pane selected.
APPEARANCE_PANE = "Appearance"
CHANGE_AVATAR = "Change profile picture"
CROP_TITLE = "Crop your picture"
USE_PICTURE = "Use picture"
THEME = "Theme"

BACK_TO_CHANNELS = "Back to channels"

# AppAvatar's suffix while a speaking ring is lit; composed with a name.
SPEAKING = ", speaking"

# Presence lives on the rail footer now, not in settings.
CHANGE_STATUS = "Change your status"
DND = "Do not disturb"

# Space settings
INVITES = "Invites"
# The embedded pane's own row, distinct from the nav row by its value suffix.
WHO_CAN_JOIN_ROW = "Who can join, currently"
JOIN_OPEN = "Anyone with the address"
JOIN_INVITE = "People with an invite"
ROLES = "Roles"
NEW_ROLE = "Create role"
ROLE_NAME = "Role name"
CREATE_ROLE = "Create role"

# Voice
IN_CALL = "in call"
SHARE_SCREEN = "Share a screen"
SHARING_NOTICE = "You are sharing your screen"
STOP_SHARING = "Stop sharing"
MUTE = "Mute"
UNMUTE = "Unmute"
LEAVE_CALL = "Leave call"

# Calling in a DM
START_DM = "Message"
DM_CALL = "Call"
DM_CALL_BACK = "Back to messages"

# What the person who was called sees; see call_record_view.dart.
MISSED_CALL = "Missed call"

# Replies: only the rendered quote is reachable here, never "Reply" itself (see e2e_replies.py).
REPLY_UNAVAILABLE = "Message unavailable"
REPLY_UNAVAILABLE_QUOTE = "Reply to a message that is not available"
JUMP_FAILED = "Could not find that message."

# Threads: the reply-count affordance and the header's close tooltip, never the bar's own title (see e2e_threads.py).
THREAD_HEADER = "Close thread"
# The docked thread's own composer/send, distinct from COMPOSER/SEND because both are on screen at once (see e2e_threads.py).
THREAD_COMPOSER = "Thread composer"
THREAD_SEND = "Send reply"

# The message menu: reached with a right-click, see e2e_input.py.
REPLY_IN_THREAD = "Reply in thread"
MENU_MORE = "More"
MENU_BACK = "Back"
MENU_DELETE = "Delete"
MENU_COPY_TEXT = "Copy text"
MENU_SELECT = "Select messages"
MENU_REPORT = "Report message"
MENU_BLOCK = "Block user"
QUICK_REACTIONS = ("Thumbs up", "Heart", "Laughing", "Celebrate", "Eyes")
MENU_VERBS = ("Copy text", "Copy link", "Forward message", "Save message",
              "Pin")
MENU_SECOND_PAGE = (MENU_SELECT, MENU_REPORT, MENU_BLOCK)

# Renaming a member from the member card
MEMBER_LIST = "Toggle member list"
MODERATE = "Moderate..."
RENAME_MEMBER = "Rename..."
NICKNAME_FIELD = "Nickname"
SAVE_NAME = "Save name"

# Canvas
OPEN_CANVAS = "Open canvas"
CLOSE_CANVAS = "Close canvas"
PEN_TOOL = "Pen"
NOTE_TOOL = "Note"
SHAPE_TOOL = "Shape"
ERASER_TOOL = "Eraser"
PAN_TOOL = "Pan"
UNDO = "Undo"
MORE_CANVAS_ACTIONS = "More canvas actions"
SHOW_ACTIVITY_LOG = "Show activity log"
HIDE_ACTIVITY_LOG = "Hide activity log"
CLEAR_CANVAS = "Clear canvas"
BRING_TO_FRONT = "Bring to front"
SEND_TO_BACK = "Send to back"
NOTE_TEXT_FIELD = "What do you want to remember?"
ADD_NOTE = "Add note"

# The fixture channels the seed creates
TEXT_CHANNEL = "general"
VOICE_CHANNEL = "lounge"

# Messages the run sends, referred to again when reacting to or reporting them
FIRST_MESSAGE = "first message from alice"
REPLY_MESSAGE = "and a reply from bob"
