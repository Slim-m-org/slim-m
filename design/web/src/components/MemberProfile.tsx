import type { HTMLAttributes } from 'react';
import { Avatar } from './Avatar';
import { Icon, type IconName } from './Icon';
import { Menu, MenuDivider, MenuItem } from './Menu';
import { Sheet } from './Sheet';
import type { StatusDotStatus } from './StatusDot';

export type MemberProfilePresentation = 'popover' | 'sheet';

export interface MemberProfileActivity {
  icon?: IconName;
  /** Small line above the title, such as "Listening to". */
  heading: string;
  title: string;
  subtitle?: string;
}

export interface MemberProfileBotCommand {
  name: string;
  description: string;
}

export interface MemberProfileProps extends Omit<HTMLAttributes<HTMLDivElement>, 'title'> {
  /** popover is the 300px anchored card for pointer widths; sheet is the bottom sheet with a handle and 44px rows for compact. */
  presentation?: MemberProfilePresentation;
  userId?: string;
  displayName: string;
  username: string;
  /** Shown after the handle when a space nickname hides the account name. */
  accountName?: string;
  pronouns?: string;
  about?: string;
  status?: StatusDotStatus;
  /** The presence word under the handle, such as "online" or "away". */
  statusWord?: string;
  /** Replaces the status line with an accent "in <channel> with you" line. */
  inCallWith?: string;
  /** Square avatar for a bot. */
  isBot?: boolean;
  /** Static 2px avatar ring in the member's profile colour. */
  ringColor?: string;
  roles?: string[];
  /** Already formatted, such as "joined Mar 2025". */
  joinedLabel?: string;
  activity?: MemberProfileActivity;
  /** Remaining time of an active timeout, such as "42m". */
  timedOutFor?: string;
  /** Bot only: the prefix its commands answer to, and the commands (three shown, the rest behind Show more). */
  commandPrefix?: string;
  commands?: MemberProfileBotCommand[];
  /** The viewer's private note, or empty for the dashed placeholder. */
  note?: string;
  /** Your own card shows a single Profile settings row instead of the member actions. */
  isSelf?: boolean;
  /** Adds the Moderate row. */
  canModerate?: boolean;
  /** Swaps Block for Unblock. */
  blocked?: boolean;
}

const COLLAPSED_COMMANDS = 3;

/** A member's profile card: avatar, names, status or shared-call line, about, activity, roles, join date, then the actions. Use as the anchored popover on pointer widths and as the bottom sheet on compact windows; the presentation is explicit because they are different surfaces. */
export function MemberProfile({
  presentation = 'popover',
  displayName,
  username,
  accountName,
  pronouns,
  about,
  status,
  statusWord,
  inCallWith,
  isBot = false,
  ringColor,
  roles = [],
  joinedLabel,
  activity,
  timedOutFor,
  commandPrefix,
  commands = [],
  note,
  isSelf = false,
  canModerate = false,
  blocked = false,
  userId,
  className,
  ...rest
}: MemberProfileProps) {
  const touch = presentation === 'sheet';
  const handle = [`@${username}`, accountName && `account name ${accountName}`, pronouns].filter(Boolean).join(' · ');
  const shown = commands.slice(0, COLLAPSED_COMMANDS);
  const hidden = commands.length - shown.length;

  const body = (
    <>
      <div className="sm-member-profile__header">
        <div className={timedOutFor ? 'sm-member-profile__avatar sm-member-profile__avatar--dim' : 'sm-member-profile__avatar'}>
          <Avatar
            name={displayName}
            tintKey={userId}
            size={44}
            shape={isBot ? 'square' : 'circle'}
            status={status}
            speaking={inCallWith != null}
            ringColor={inCallWith ? undefined : ringColor}
          />
        </div>
        <div className="sm-member-profile__identity">
          <span className="sm-member-profile__name">{displayName}</span>
          <span className="sm-member-profile__handle">{handle}</span>
          {inCallWith ? (
            <span className="sm-member-profile__call">
              <Icon name="speaker" size={16} />
              <span>in {inCallWith} with you</span>
            </span>
          ) : (
            <span className="sm-member-profile__handle">{isSelf ? [statusWord, 'you'].filter(Boolean).join(' - ') : (statusWord ?? '')}</span>
          )}
        </div>
      </div>
      {about && <p className="sm-member-profile__about">{about}</p>}
      {activity && (
        <div className="sm-member-profile__activity">
          <span className="sm-member-profile__cover" aria-hidden>
            <Icon name={activity.icon ?? 'playing'} size={20} />
          </span>
          <span className="sm-member-profile__activity-text">
            <span className="sm-member-profile__handle">{activity.heading}</span>
            <span className="sm-member-profile__activity-title">{activity.title}</span>
            {activity.subtitle && <span className="sm-member-profile__handle">{activity.subtitle}</span>}
          </span>
        </div>
      )}
      {(roles.length > 0 || joinedLabel) && (
        <div className="sm-member-profile__roles">
          {roles.map((role) => (
            <span key={role} className="sm-member-profile__role">
              {role}
            </span>
          ))}
          {joinedLabel && <span className="sm-member-profile__joined">{joinedLabel}</span>}
        </div>
      )}
      {timedOutFor && (
        <div className="sm-member-profile__timeout" role="note">
          <Icon name="clock" size={16} />
          <span>
            <span className="sm-member-profile__timeout-head">Timed out - {timedOutFor} remaining</span>
            <span className="sm-member-profile__handle">Can read messages and view the canvas; can't draw, send messages, or join voice.</span>
          </span>
        </div>
      )}
      {isBot && commandPrefix && commands.length > 0 && (
        <div className="sm-member-profile__commands">
          <span className="sm-member-profile__label">Commands - answers to {commandPrefix}</span>
          {shown.map((c) => (
            <span key={c.name} className="sm-member-profile__command">
              <span className="sm-member-profile__command-name">
                {commandPrefix}
                {c.name}{' '}
              </span>
              <span className="sm-member-profile__handle">{c.description}</span>
            </span>
          ))}
          {hidden > 0 && <span className="sm-member-profile__more">Show {hidden} more</span>}
        </div>
      )}
      <MenuDivider />
      {isSelf ? (
        <MenuItem label="Profile settings" icon="settings" touch={touch} />
      ) : (
        <>
          <MenuItem label="Message" icon="send" touch={touch} />
          <div className="sm-member-profile__note">
            <div className={note ? 'sm-member-profile__note-box sm-member-profile__note-box--filled' : 'sm-member-profile__note-box'}>
              {note ?? <span className="sm-member-profile__placeholder">Add a private note</span>}
            </div>
            <span className="sm-member-profile__micro">only you</span>
          </div>
          {canModerate && (
            <>
              <MenuDivider />
              <MenuItem label="Moderate..." icon="shield" submenu touch={touch} />
            </>
          )}
          <MenuDivider />
          <MenuItem label="Report user" icon="report" touch={touch} />
          {blocked ? <MenuItem label="Unblock" icon="restoreAccess" touch={touch} /> : <MenuItem label="Block" icon="revoke" tone="danger" touch={touch} />}
        </>
      )}
    </>
  );

  const classes = ['sm-member-profile', `sm-member-profile--${presentation}`, className].filter(Boolean).join(' ');
  if (touch) {
    return (
      <Sheet className={classes} aria-label={displayName} {...rest}>
        {body}
      </Sheet>
    );
  }
  return (
    <Menu width={300} className={classes} aria-label={displayName} role="dialog" {...rest}>
      {body}
    </Menu>
  );
}
