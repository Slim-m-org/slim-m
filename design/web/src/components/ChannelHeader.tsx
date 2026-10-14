import type { HTMLAttributes } from 'react';
import { Avatar } from './Avatar';
import { Icon, type IconName } from './Icon';
import { IconButton } from './IconButton';

export type ChannelHeaderKind = 'text' | 'voice' | 'dm' | 'notes';

export interface ChannelHeaderProps extends Omit<HTMLAttributes<HTMLElement>, 'children'> {
  /** Channel name, or the peer's name in a DM. */
  name: string;
  /** text shows a hash, voice a speaker, dm the peer's avatar, notes the notebook glyph of the self-DM. */
  kind?: ChannelHeaderKind;
  /** One line shown after the name on wide layouts and under it on compact. Omit for none. */
  topic?: string;
  /** @everyone cannot view this channel: swaps the glyph for a lock. Ignored for dm and notes. */
  restricted?: boolean;
  /** Lights the search button. */
  searchOpen?: boolean;
  /** Lights the member button while the member pane is open. */
  membersOpen?: boolean;
  /** Voice channels only: show the toggle for the docked text chat on wide layouts. */
  textChatToggle?: boolean;
  textChatOpen?: boolean;
  onBack?: () => void;
  onSearch?: () => void;
  onPins?: () => void;
  onThreads?: () => void;
  onMembers?: () => void;
  onTextChat?: () => void;
  onCall?: () => void;
}

function Glyph({ name, kind, restricted }: Pick<ChannelHeaderProps, 'name' | 'kind' | 'restricted'>) {
  if (kind === 'dm') return <Avatar name={name} size={24} />;
  const icon: IconName = kind === 'notes' ? 'notebook' : restricted ? 'restrictedChannel' : kind === 'voice' ? 'voice' : 'hash';
  return (
    <span className="sm-channelheader__glyph">
      <Icon name={icon} size={20} />
    </span>
  );
}

/** The bar above a conversation: channel glyph, name, topic and the pane actions. At 600px and up it is a 52px bar with the topic inline; below 600 it becomes a 48px app bar with a back button, a stacked title, touch-size actions and the member button opening the member drawer. */
export function ChannelHeader({
  name,
  kind = 'text',
  topic,
  restricted = false,
  searchOpen = false,
  membersOpen = false,
  textChatToggle = false,
  textChatOpen = false,
  onBack,
  onSearch,
  onPins,
  onThreads,
  onMembers,
  onTextChat,
  onCall,
  className,
  ...rest
}: ChannelHeaderProps) {
  const voice = kind === 'voice';
  const dm = kind === 'dm';
  const glyph = <Glyph name={name} kind={kind} restricted={restricted} />;
  return (
    <header className={['sm-channelheader', className].filter(Boolean).join(' ')} {...rest}>
      <div className="sm-channelheader__wide">
        <div className="sm-channelheader__title">
          {glyph}
          <span className="sm-channelheader__name">{name}</span>
          {topic && (
            <>
              <span className="sm-channelheader__rule" aria-hidden />
              <span className="sm-channelheader__topic">{topic}</span>
            </>
          )}
        </div>
        <IconButton icon="pin" label="Pinned messages" onClick={onPins} />
        {!voice && <IconButton icon="thread" label="Threads" onClick={onThreads} />}
        {dm && <IconButton icon="startCall" label="Start a call" onClick={onCall} />}
        {voice && textChatToggle && <IconButton icon="chat" label="Toggle text chat" active={textChatOpen} onClick={onTextChat} />}
        <IconButton icon="search" label="Search messages" active={searchOpen} onClick={onSearch} />
        {!dm && <IconButton icon="members" label="Toggle member list" active={membersOpen} onClick={onMembers} />}
      </div>
      <div className="sm-channelheader__compact">
        <IconButton icon="back" label="Back to channels" touch onClick={onBack} />
        <div className="sm-channelheader__stack">
          <div className="sm-channelheader__title">
            {glyph}
            <span className="sm-channelheader__name">{name}</span>
          </div>
          {topic && <span className="sm-channelheader__topic">{topic}</span>}
        </div>
        {!voice && <IconButton icon="search" label="Search messages" touch active={searchOpen} onClick={onSearch} />}
        {!voice && <IconButton icon="pin" label="Pinned messages" touch onClick={onPins} />}
        {!voice && !dm && <IconButton icon="thread" label="Threads" touch onClick={onThreads} />}
        {dm && <IconButton icon="startCall" label="Start a call" touch onClick={onCall} />}
        {voice && <IconButton icon="chat" label="Text chat" touch active={textChatOpen} onClick={onTextChat} />}
        {!dm && <IconButton icon="members" label="Show members" touch onClick={onMembers} />}
      </div>
    </header>
  );
}
