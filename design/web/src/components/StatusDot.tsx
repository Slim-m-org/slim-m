import type { HTMLAttributes } from 'react';

export type StatusDotStatus = 'online' | 'away' | 'dnd' | 'offline' | 'hidden' | 'unknown';

export interface StatusDotProps extends HTMLAttributes<HTMLSpanElement> {
  /** online is a disc, away a triangle, dnd a notched square, offline a hollow ring, hidden a slashed ring. unknown draws nothing. */
  status?: StatusDotStatus;
  /** Diameter in px. Defaults to 10. */
  size?: number;
  /** What the dot sits on; the notch and slash are punched out in this colour. Defaults to the base surface. */
  backgroundColor?: string;
}

const words: Record<Exclude<StatusDotStatus, 'unknown'>, string> = {
  online: 'online',
  away: 'away',
  dnd: 'do not disturb',
  offline: 'offline',
  hidden: 'appearing offline',
};

/** A presence dot. Each state has its own silhouette as well as its own colour, so it reads in greyscale. */
export function StatusDot({ status = 'offline', size = 10, backgroundColor, className, style, ...rest }: StatusDotProps) {
  const classes = ['sm-status-dot', className].filter(Boolean).join(' ');
  if (status === 'unknown') {
    return <span className={classes} style={{ width: size, height: size, ...style }} aria-hidden {...rest} />;
  }
  const w = size;
  const c = w / 2;
  const ring = Math.max(2, w * 0.26);
  const color = `var(--status-${status === 'hidden' ? 'offline' : status})`;
  const barHeight = Math.max(2, w * 0.18);
  return (
    <span className={classes} role="img" aria-label={words[status]} style={{ width: size, height: size, ...style }} {...rest}>
      <svg width={w} height={w} viewBox={`0 0 ${w} ${w}`} overflow="visible" aria-hidden>
        {status === 'online' && <circle cx={c} cy={c} r={c} fill={color} />}
        {status === 'away' && <polygon points={`${c},0 ${w},${w} 0,${w}`} fill={color} />}
        {status === 'dnd' && (
          <>
            <rect width={w} height={w} rx={3} fill={color} />
            <rect x={c - (w * 0.62) / 2} y={c - barHeight / 2} width={w * 0.62} height={barHeight} fill={backgroundColor ?? 'var(--surface-base)'} />
          </>
        )}
        {(status === 'offline' || status === 'hidden') && (
          <circle cx={c} cy={c} r={c - ring / 2} fill="none" stroke={color} strokeWidth={ring} />
        )}
        {status === 'hidden' && <rect x={c - (w + 2) / 2} y={c - 1} width={w + 2} height={2} fill={color} transform={`rotate(-45 ${c} ${c})`} />}
      </svg>
    </span>
  );
}
