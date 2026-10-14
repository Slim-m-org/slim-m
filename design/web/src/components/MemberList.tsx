import type { HTMLAttributes } from 'react';
import { Avatar } from './Avatar';
import { Badge } from './Badge';
import { Icon, type IconName } from './Icon';
import { ListRow } from './ListRow';
import type { StatusDotStatus } from './StatusDot';

export interface MemberEntry {
  id: string;
  name: string;
  status?: StatusDotStatus;
  /** Second line: what they are doing or their status text. */
  activity?: string;
  activityIcon?: IconName;
  /** Role chip. Omit when the row sits under that role's own section. */
  role?: string;
  /** Marks a bot with a neutral Bot tag and a square avatar. */
  bot?: boolean;
  avatarSrc?: string;
}

export interface MemberSection {
  /** Section heading, such as Moderator, Online or Offline. Shown uppercase with the count. */
  label: string;
  members: MemberEntry[];
}

export interface MemberListProps extends Omit<HTMLAttributes<HTMLElement>, 'children'> {
  sections: MemberSection[];
  /** Shown in the header as MEMBERS and the total. Defaults to the sum of the sections. */
  total?: number;
  /** The id of a row to draw selected. */
  selectedId?: string;
  onSelectMember?: (id: string) => void;
}

/** The member pane: a MEMBERS count header, then sections by role and presence with a 36px row per person (avatar with presence, name, activity line, role or Bot chip). Offline rows are dimmed. It fills its container (236px docked, the drawer width on compact) and, below 600, rows grow to 44px touch height. */
export function MemberList({ sections, total, selectedId, onSelectMember, className, ...rest }: MemberListProps) {
  const count = total ?? sections.reduce((n, s) => n + s.members.length, 0);
  return (
    <aside className={['sm-memberlist', className].filter(Boolean).join(' ')} aria-label="Members" {...rest}>
      <div className="sm-memberlist__header">Members {'·'} {count}</div>
      <div className="sm-memberlist__scroll">
        {sections.map((section) => (
          <section key={section.label}>
            <div className="sm-memberlist__label">
              {section.label} {'·'} {section.members.length}
            </div>
            {section.members.map((m) => {
              const status = m.status ?? 'offline';
              return (
                <ListRow
                  key={m.id}
                  className="sm-memberlist__row"
                  label={m.name}
                  subtitle={m.activity}
                  subtitleIcon={m.activityIcon}
                  muted={status === 'offline' || status === 'hidden'}
                  selected={m.id === selectedId}
                  leading={<Avatar name={m.name} src={m.avatarSrc} size={32} status={status} shape={m.bot ? 'square' : 'circle'} />}
                  trailing={m.bot ? <Badge variant="tag" label="Bot" /> : m.role ? <Badge variant="role" label={m.role} /> : undefined}
                  onClick={() => onSelectMember?.(m.id)}
                />
              );
            })}
          </section>
        ))}
      </div>
    </aside>
  );
}
