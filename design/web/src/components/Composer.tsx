import type { HTMLAttributes } from 'react';
import { ErrorState } from './ErrorState';
import { Icon } from './Icon';
import { IconButton } from './IconButton';

export interface ComposerAttachment {
  name: string;
  /** uploading shows a progress bar over `progress`; failed draws a danger edge and `error`. */
  status?: 'ready' | 'uploading' | 'failed';
  /** 0 to 1, for uploading. */
  progress?: number;
  /** Size line shown with progress, e.g. "2.4 MB". */
  size?: string;
  error?: string;
}

export interface ComposerReply {
  author: string;
  snippet?: string;
}

export interface ComposerProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** Channel name without the hash. Empty drops the "#name" part of the hint. */
  channelName?: string;
  /** Draft text. Empty shows the "Message #channel" hint. */
  value?: string;
  replyTo?: ComposerReply;
  attachments?: ComposerAttachment[];
  /** Seconds left in slow mode. Above 0 shows the banner and disables send. */
  slowModeSeconds?: number;
  /** Whether the GIF tab exists; changes only the emoji button's label. */
  gifEnabled?: boolean;
}

function StagedTile({ file }: { file: ComposerAttachment }) {
  const status = file.status ?? 'ready';
  const percent = Math.floor((file.progress ?? 0) * 100);
  return (
    <div className={['sm-composer__tile', status === 'failed' && 'sm-composer__tile--failed'].filter(Boolean).join(' ')}>
      <span className="sm-composer__thumb">
        {status === 'failed' ? <Icon name="failed" size={20} color="var(--danger-text)" /> : <Icon name="attachFile" size={16} />}
      </span>
      <span className="sm-composer__tile-text">
        <span className="sm-composer__tile-name">{file.name}</span>
        {status === 'uploading' && (
          <>
            <span className="sm-composer__tile-meta">
              {percent}%{file.size ? ` of ${file.size}` : ''}
            </span>
            <span className="sm-composer__progress">
              <span style={{ width: `${percent}%` }} />
            </span>
          </>
        )}
        {status === 'failed' && file.error && <span className="sm-composer__tile-error">{file.error}</span>}
      </span>
      <Icon name={status === 'failed' ? 'retry' : 'dismiss'} size={16} className="sm-composer__tile-action" />
    </div>
  );
}

/** The message composer: optional reply banner, staged attachments, slow-mode notice, then the input bar with attach, poll, code, emoji and send. At 600px and wider the bar carries every action as a 30px pointer button; below 600px attach, poll and code fold into one "More actions" button, the controls grow to 44px and the field is 44px tall. */
export function Composer({
  channelName = '',
  value = '',
  replyTo,
  attachments = [],
  slowModeSeconds = 0,
  gifEnabled = true,
  className,
  ...rest
}: ComposerProps) {
  const hasText = value.trim().length > 0;
  const canSend = (hasText || attachments.some((a) => a.status !== 'failed')) && slowModeSeconds <= 0;
  const emojiLabel = gifEnabled ? 'Insert emoji or a GIF' : 'Insert emoji';
  const send = <IconButton icon="send" label="Send message" disabled={!canSend} />;
  const sendTouch = <IconButton icon="send" label="Send message" touch disabled={!canSend} />;
  return (
    <div className={['sm-composer', className].filter(Boolean).join(' ')} {...rest}>
      {slowModeSeconds > 0 && (
        <div className="sm-composer__banner">
          <ErrorState message={`Slow mode: wait ${slowModeSeconds}s before sending again.`} />
        </div>
      )}
      {attachments.length > 0 && (
        <div className="sm-composer__staged">
          {attachments.map((file) => (
            <StagedTile key={file.name} file={file} />
          ))}
        </div>
      )}
      {replyTo && (
        <div className="sm-composer__reply">
          <Icon name="reply" size={16} width={14} height={14} />
          <span className="sm-composer__reply-text">
            <span className="sm-composer__reply-author">Replying to {replyTo.author}</span>
            {replyTo.snippet && <span>{`  ${replyTo.snippet}`}</span>}
          </span>
          <IconButton icon="dismiss" label="Cancel reply" size="sm" />
        </div>
      )}
      <div className="sm-composer__bar">
        <span className="sm-composer__wide">
          <IconButton icon="add" label="Attach a file" />
        </span>
        <span className="sm-composer__compact">
          <IconButton icon="add" label="More actions" touch />
        </span>
        <div className={['sm-composer__field', !hasText && 'sm-composer__field--hint'].filter(Boolean).join(' ')}>
          {hasText ? (
            value
          ) : (
            <>
              Message
              {channelName && (
                <>
                  {' '}
                  <span className="sm-composer__hint-channel">#{channelName}</span>
                </>
              )}
            </>
          )}
        </div>
        <span className="sm-composer__wide sm-composer__actions">
          <IconButton icon="poll" label="Create a poll" />
          <IconButton icon="code" label="Insert code" />
          <IconButton icon="smile" label={emojiLabel} />
          {send}
        </span>
        <span className="sm-composer__compact sm-composer__actions">
          <IconButton icon="smile" label={emojiLabel} touch />
          {sendTouch}
        </span>
      </div>
    </div>
  );
}
