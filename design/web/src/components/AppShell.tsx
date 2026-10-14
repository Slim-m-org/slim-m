import type { HTMLAttributes, ReactNode } from 'react';

export interface AppShellProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children' | 'content'> {
  /** Usually a ChannelRail. Docked at 600px and up, a left drawer below. */
  rail: ReactNode;
  /** Usually a ChannelHeader, pinned above the content. */
  header?: ReactNode;
  /** The conversation: messages and composer. */
  content: ReactNode;
  /** Usually a MemberList. Docked at 836px and up, an optional right drawer below. */
  members?: ReactNode;
  /** A StatusBanner (or several) that spans the whole shell and pushes it down. */
  banner?: ReactNode;
  /** Compact only: draws the rail as a left drawer over a scrim. */
  railOpen?: boolean;
  /** Where the member pane does not dock (compact, and medium under 836px): draws it as a right drawer over a scrim. */
  membersOpen?: boolean;
  /** Where the member pane docks, false hides it, the way the header toggle does. Defaults to true. */
  membersDocked?: boolean;
  /** Called when the scrim is pressed. */
  onDismiss?: () => void;
}

/** The signed-in layout frame. Expanded (1000px and up): rail, content, member pane side by side. Medium (600 to 999): rail and content; the member pane docks only from 836px, below that it is a right drawer. Compact (under 600): content alone, with the rail and members as drawers over a scrim, opened with `railOpen` and `membersOpen`. Give the SlimRoot an explicit height; the shell fills it. */
export function AppShell({ rail, header, content, members, banner, railOpen = false, membersOpen = false, membersDocked = true, onDismiss, className, ...rest }: AppShellProps) {
  const classes = [
    'sm-appshell',
    railOpen && 'sm-appshell--rail-open',
    membersOpen && 'sm-appshell--members-open',
    !membersDocked && 'sm-appshell--members-hidden',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  return (
    <div className={classes} {...rest}>
      {banner && <div className="sm-appshell__banner">{banner}</div>}
      <div className="sm-appshell__body">
        <aside className="sm-appshell__rail">
          {rail}
        </aside>
        <div className="sm-appshell__main">
          {header}
          <div className="sm-appshell__content">{content}</div>
        </div>
        {members && <aside className="sm-appshell__members">{members}</aside>}
        <div className="sm-appshell__scrim" onClick={onDismiss} aria-hidden />
      </div>
    </div>
  );
}
