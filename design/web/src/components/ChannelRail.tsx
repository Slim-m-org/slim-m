import type { HTMLAttributes } from 'react';
import { Avatar } from './Avatar';
import { Icon } from './Icon';
import { IconButton } from './IconButton';
import { Kbd } from './Kbd';
import { ListRow } from './ListRow';
import type { StatusDotStatus } from './StatusDot';

export interface RailParticipant {
  name: string;
  speaking?: boolean;
  muted?: boolean;
  screenSharing?: boolean;
  camera?: boolean;
}

export interface RailChannel {
  id: string;
  name: string;
  kind?: 'text' | 'voice';
  selected?: boolean;
  /** Bold label and a dot; suppressed when muted. */
  unread?: boolean;
  /** Accent diamond; the only marker that survives mute. */
  mentioned?: boolean;
  muted?: boolean;
  /** @everyone cannot view it: a lock replaces the hash or speaker. */
  restricted?: boolean;
  /** Voice: people joining are muted, shown as a mic-off glyph at the row end. */
  joinMuted?: boolean;
  /** Voice: a lobby that creates temporary rooms. */
  lobby?: boolean;
  /** Voice: shown as `present/limit` at the row end. */
  userLimit?: number;
  /** Voice: who is in the call, listed under the row. */
  participants?: RailParticipant[];
}

export interface RailCategory {
  id: string;
  /** Empty for the uncategorised group, which has no label. */
  name: string;
  collapsed?: boolean;
  channels: RailChannel[];
}

export interface RailUser {
  name: string;
  status?: StatusDotStatus;
  /** Custom status text, shown after the presence word. */
  statusText?: string;
  /** Mic and headphone buttons are disabled outside a call. */
  inCall?: boolean;
  micMuted?: boolean;
  deafened?: boolean;
}

export interface ChannelRailProps extends Omit<HTMLAttributes<HTMLElement>, 'children'> {
  spaceName: string;
  categories: RailCategory[];
  user: RailUser;
  /** An update is waiting: dots the settings gear. */
  updatePending?: boolean;
  onSelectChannel?: (id: string) => void;
}

const MAX_NAMED = 8;
const statusWord: Record<StatusDotStatus, string> = { online: 'Online', away: 'Away', dnd: 'Do not disturb', offline: 'Offline', hidden: 'Appearing offline', unknown: '' };

function leadingIcon(c: RailChannel) {
  const name = c.lobby ? 'voiceLobby' : c.restricted ? 'restrictedChannel' : c.kind === 'voice' ? 'voice' : 'hash';
  return <Icon name={name} size={16} className="sm-channelrail__kind" />;
}

function rowEnd(c: RailChannel) {
  const present = c.participants?.length ?? 0;
  const marks = [
    c.userLimit ? <span key="limit" className="sm-channelrail__limit">{present}/{c.userLimit}</span> : null,
    c.joinMuted ? <Icon key="muted" name="micOff" size={16} aria-label="Joins muted" role="img" /> : null,
  ].filter(Boolean);
  return marks.length ? <span className="sm-channelrail__marks">{marks}</span> : undefined;
}

function Participants({ list }: { list: RailParticipant[] }) {
  const shown = list.slice(0, MAX_NAMED);
  const more = list.length - shown.length;
  return (
    <div className="sm-channelrail__people">
      {shown.map((p) => (
        <div key={p.name} className="sm-channelrail__person">
          <Avatar name={p.name} size={20} speaking={p.speaking} />
          <span className="sm-channelrail__person-name">{p.name}</span>
          {p.screenSharing && <Icon name="screenShare" size={16} className="sm-channelrail__glyph" />}
          {p.camera && <Icon name="camera" size={16} className="sm-channelrail__glyph" />}
          {p.muted && <Icon name="micOff" size={16} className="sm-channelrail__glyph" />}
        </div>
      ))}
      {more > 0 && <div className="sm-channelrail__more">+{more} more</div>}
    </div>
  );
}

/** The sunken channel list: space header, a search trigger, category sections with text and voice rows, and the footer with your presence and mic, headphone and settings buttons. It fills its container (248px docked on expanded, 240px on medium, the drawer width on compact); below 600 the rows grow to 44px touch height and the footer hides the search hint. */
export function ChannelRail({ spaceName, categories, user, updatePending = false, onSelectChannel, className, ...rest }: ChannelRailProps) {
  const status = user.status ?? 'online';
  const second = [statusWord[status], user.statusText].filter(Boolean).join(' · ');
  return (
    <nav className={['sm-channelrail', className].filter(Boolean).join(' ')} aria-label="Channels" {...rest}>
      <div className="sm-channelrail__header">
        <Avatar name={spaceName} shape="square" size={24} placeholder={<span className="sm-channelrail__mark">{spaceName.slice(0, 1).toUpperCase()}</span>} />
        <span className="sm-channelrail__space">{spaceName}</span>
        <IconButton icon="chevronDown" label="Space menu" size="sm" iconSize={16} />
      </div>
      <div className="sm-channelrail__search">
        <Icon name="search" size={16} />
        <span className="sm-channelrail__search-text">Search</span>
        <span className="sm-channelrail__hint"><Kbd label="Ctrl" /><Kbd label="K" /></span>
      </div>
      <div className="sm-channelrail__scroll">
        {categories.map((cat) => (
          <section key={cat.id} className="sm-channelrail__section">
            {cat.name && (
              <div className="sm-channelrail__label">
                <Icon name={cat.collapsed ? 'chevronRight' : 'chevronDown'} size={16} />
                <span className="sm-channelrail__label-text">{cat.name}</span>
              </div>
            )}
            {!cat.collapsed &&
              cat.channels.map((c) => (
                <div key={c.id}>
                  <ListRow
                    label={c.name}
                    leading={leadingIcon(c)}
                    selected={c.selected}
                    unread={c.unread}
                    mentioned={c.mentioned}
                    muted={c.muted}
                    trailing={rowEnd(c)}
                    onClick={() => onSelectChannel?.(c.id)}
                  />
                  {c.participants && c.participants.length > 0 && <Participants list={c.participants} />}
                </div>
              ))}
          </section>
        ))}
      </div>
      <div className="sm-channelrail__footer">
        <Avatar name={user.name} size={32} status={status} />
        <span className="sm-channelrail__who">
          <span className="sm-channelrail__who-name">{user.name}</span>
          <span className="sm-channelrail__who-status">{second}</span>
        </span>
        <span className="sm-channelrail__controls">
          <IconButton icon={user.micMuted ? 'micOff' : 'mic'} label={user.micMuted ? 'Unmute' : 'Mute'} disabled={!user.inCall} />
          <IconButton icon="headphones" label={user.deafened ? 'Undeafen' : 'Deafen'} active={user.deafened} disabled={!user.inCall} />
          <span className="sm-channelrail__gear">
            <IconButton icon="settings" label={updatePending ? 'Personal settings, an update is available' : 'Personal settings'} />
            {updatePending && <span className="sm-channelrail__update" aria-hidden />}
          </span>
        </span>
      </div>
    </nav>
  );
}
