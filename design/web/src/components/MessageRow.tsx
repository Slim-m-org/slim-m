import type { HTMLAttributes, ReactNode } from 'react';
import { Avatar } from './Avatar';
import { Badge } from './Badge';
import { Button } from './Button';
import { Chip } from './Chip';
import { Icon } from './Icon';
import { IconButton } from './IconButton';

export type MessageStatus = 'sent' | 'pending' | 'failed';
export type MessageDensity = 'compact' | 'normal' | 'spacious';

export interface MessageReaction {
  /** User content, written as a \u{...} escape in source. */
  emoji: string;
  count: number;
  /** The reader reacted. */
  active?: boolean;
}

export interface MessageReplyQuote {
  author: string;
  /** One line of the parent; "Message unavailable" when it could not be resolved. */
  snippet: string;
}

export interface MessageRowProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  author: string;
  /** Formatted time of day, e.g. "9:41a". Shown in the header, or in the gutter of a grouped row on hover. */
  time: string;
  /** Message text. Use <Mention> for an @mention pill. */
  body?: ReactNode;
  avatarSrc?: string;
  /** A continuation of the same author's previous message: no avatar or header. */
  grouped?: boolean;
  /** A non-human author: square avatar and a Bot badge. */
  bot?: boolean;
  replyTo?: MessageReplyQuote;
  reactions?: MessageReaction[];
  /** An attachment slot. Pass `true` for the stand-in image block, or your own node. */
  attachment?: ReactNode;
  edited?: boolean;
  /** pending dims the body and shows "sending"; failed adds a danger edge and Retry/Discard. */
  status?: MessageStatus;
  failureReason?: string;
  /** Wide only: draws the row fill and the hover action toolbar so a mock can show it. */
  hovered?: boolean;
  /** Vertical rhythm only: avatar 28 / 40 / 40, group gap 4 / 8 / 12. */
  density?: MessageDensity;
  /** Extra content under the body, inside the message column. */
  children?: ReactNode;
}

/** An @mention pill: accent-soft fill, accent text, medium weight. */
export function Mention({ children }: { children: ReactNode }) {
  return <span className="sm-message-row__mention">{children}</span>;
}

/** A striped stand-in for an image or video attachment, 420 by 168 and capped at the column, captioned with what belongs there; never a real photo. */
export function AttachmentPlaceholder({ caption = 'image' }: { caption?: string }) {
  return (
    <div className="sm-message-row__attachment" aria-hidden>
      <span className="sm-message-row__attachment-caption">{caption}</span>
    </div>
  );
}

function Toolbar() {
  return (
    <div className="sm-message-row__toolbar" role="toolbar" aria-label="Message actions">
      <IconButton icon="smile" label="Add reaction" iconSize={16} />
      <IconButton icon="reply" label="Reply" iconSize={16} />
      <IconButton icon="thread" label="Reply in thread" iconSize={16} />
      <IconButton icon="edit" label="Edit" iconSize={16} />
      <IconButton icon="moreHorizontal" label="More message actions" iconSize={16} />
    </div>
  );
}

function TimeMark({ time, status, compact }: { time: string; status: MessageStatus; compact?: boolean }) {
  if (status === 'failed') {
    return compact ? <Icon name="failed" size={16} width={11} height={11} className="sm-message-row__time--failed" /> : <span className="sm-message-row__time sm-message-row__time--failed">not sent</span>;
  }
  if (status === 'pending') {
    return (
      <span className="sm-message-row__time">
        <Icon name="clock" size={16} width={11} height={11} />
        {!compact && <span>sending</span>}
      </span>
    );
  }
  return <span className="sm-message-row__time">{time}</span>;
}

/** One chat message as the transcript draws it: avatar and header, or a grouped continuation, then reply quote, body, attachment, reactions and send state. At 600px and wider a hovered row shows the action toolbar; below 600px there is no toolbar and the gutter tightens from 20px to 10px (actions live in the long-press menu). */
export function MessageRow({
  author,
  time,
  body,
  avatarSrc,
  grouped = false,
  bot = false,
  replyTo,
  reactions,
  attachment,
  edited = false,
  status = 'sent',
  failureReason,
  hovered = false,
  density = 'normal',
  children,
  className,
  ...rest
}: MessageRowProps) {
  const classes = [
    'sm-message-row',
    `sm-message-row--${density}`,
    grouped && 'sm-message-row--grouped',
    hovered && 'sm-message-row--hovered',
    status === 'failed' && 'sm-message-row--failed',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  const avatarSize = density === 'compact' ? 28 : 40;
  const unsent = status !== 'sent';
  const mark = edited ? <span className="sm-message-row__edited">edited</span> : null;
  return (
    <div className={classes} {...rest}>
      <div className="sm-message-row__inner">
        <div className="sm-message-row__lead" style={{ width: avatarSize }}>
          {grouped ? (
            (unsent || hovered) && (
              <span className="sm-message-row__gutter-time">
                <TimeMark time={time} status={status} compact />
              </span>
            )
          ) : (
            <Avatar
              name={author}
              src={avatarSrc}
              size={avatarSize}
              shape={bot ? 'square' : 'circle'}
            />
          )}
        </div>
        <div className="sm-message-row__column">
          {!grouped && (
            <div className="sm-message-row__header">
              <span className="sm-message-row__author">{author}</span>
              {bot && <Badge variant="tag" label="Bot" />}
              <TimeMark time={time} status={status} />
            </div>
          )}
          {replyTo && (
            <div className="sm-message-row__reply">
              <Icon name="reply" size={16} width={13} height={13} />
              <span className="sm-message-row__reply-text">
                <span className="sm-message-row__reply-author">{replyTo.author}</span> {replyTo.snippet}
              </span>
            </div>
          )}
          {body != null && (
            <div className={['sm-message-row__body', status === 'pending' && 'sm-message-row__body--dim'].filter(Boolean).join(' ')}>
              {body}
              {mark}
            </div>
          )}
          {body == null && mark}
          {attachment && <div className="sm-message-row__slot">{attachment === true ? <AttachmentPlaceholder /> : attachment}</div>}
          {children}
          {!unsent && reactions && reactions.length > 0 && (
            <div className="sm-message-row__reactions">
              {reactions.map((r) => (
                <Chip key={r.emoji} emoji={r.emoji} count={r.count} active={r.active} />
              ))}
            </div>
          )}
          {status === 'failed' && (
            <div className="sm-message-row__failed">
              {failureReason && <div className="sm-message-row__failure-reason">{failureReason}</div>}
              <div className="sm-message-row__failed-actions">
                <Button label="Retry" size="sm" variant="danger" />
                <Button label="Discard" size="sm" />
              </div>
            </div>
          )}
        </div>
      </div>
      {hovered && !unsent && <Toolbar />}
    </div>
  );
}
