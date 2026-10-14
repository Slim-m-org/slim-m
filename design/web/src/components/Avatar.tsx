import { useState, type HTMLAttributes, type ReactNode } from 'react';
import { Icon } from './Icon';
import { SpeakingRing } from './SpeakingRing';
import { StatusDot, type StatusDotStatus } from './StatusDot';

export type AvatarShape = 'circle' | 'square';
export type AvatarSize = 16 | 20 | 24 | 28 | 32 | 36 | 40 | 44 | 56 | 72 | 96;

export interface AvatarProps extends Omit<HTMLAttributes<HTMLSpanElement>, 'children'> {
  /** Display name: source of the initials and the accessible label. */
  name: string;
  /** Stable identity the tint is hashed from (a user id). Falls back to name. */
  tintKey?: string;
  src?: string;
  /** 16/20 rail rows, 24 smallest with a dot, 28 DM row, 32 member row, 36 default, 40 message author, 44 card, 56 canvas bubble, 72 picker, 96 incoming call. */
  size?: AvatarSize;
  /** circle for a person; square marks a non-human author (webhook, CI bot). */
  shape?: AvatarShape;
  /** Presence overlay, bottom-right. unknown and undefined draw nothing. */
  status?: StatusDotStatus;
  /** Online from a phone only: an online dot becomes a phone glyph. */
  mobileOnly?: boolean;
  /** Pulsing accent ring. Wins over ringColor. */
  speaking?: boolean;
  /** A static 2px ring in this colour, drawn when not speaking. */
  ringColor?: string;
  /** Content of a square avatar with no src; defaults to the name's initials in mono, as the app draws a bot with no picture. */
  placeholder?: ReactNode;
}

// Fixed tints and white ink, hard-coded in avatar.dart because themed text inverts on them.
const tints = ['#4E6B66', '#5C6E7A', '#6A5B6E', '#59685C', '#6A6152', '#4F5B66'];

function tintFor(source: string): string {
  let sum = 0;
  for (let i = 0; i < source.length; i++) sum = (sum + source.charCodeAt(i)) % tints.length;
  return tints[sum];
}

/** The one initials rule: first two alphanumerics, uppercased. */
export function initialsFor(name: string): string {
  return name.replace(/[^a-zA-Z0-9]/g, '').slice(0, 2).toUpperCase();
}

const DOT_HALO = 1.5;
const RING_WIDTH = 2;

function geometry(size: number, phone: boolean) {
  const dot = Math.max(8, Math.round(size * 0.3));
  const mark = dot + (phone ? 4 : 0);
  const haloRadius = mark / 2 + DOT_HALO;
  const r = size / 2;
  const axis = r + (r + haloRadius * 0.2) / Math.SQRT2;
  return { dot, mark, haloRadius, axis, fontSize: Math.max(9, Math.round(size * 0.36)), center: axis };
}

function initialsScale(size: number, withDot: boolean, g: ReturnType<typeof geometry>): number {
  const aspect = 1.2;
  const r = size / 2;
  let half = (r - RING_WIDTH) / Math.sqrt(1 + 1 / (aspect * aspect));
  if (withDot) {
    const d = g.axis - r;
    const keepOut = g.haloRadius + 1;
    while (half > 0 && Math.hypot(half - d, half / aspect - d) < keepOut) half -= 0.1;
  }
  const textWidth = g.fontSize * 1.2;
  return Math.min(1, Math.max(0, half * 2) / textWidth);
}

/** A user picture: round tinted initials for a person, a square with mono initials for a bot or webhook. Takes an optional presence dot and speaking ring without moving layout. */
export function Avatar({
  name,
  tintKey,
  src,
  size = 36,
  shape = 'circle',
  status,
  mobileOnly = false,
  speaking = false,
  ringColor,
  placeholder,
  className,
  style,
  ...rest
}: AvatarProps) {
  const [failed, setFailed] = useState(false);
  const round = shape === 'circle';
  const dot = status !== undefined && status !== 'unknown';
  const phone = dot && mobileOnly && status === 'online';
  const g = geometry(size, phone);
  const radius = round ? size / 2 : 6;
  const showImage = src && !failed;

  let content: ReactNode = showImage ? (
    <img className="sm-avatar__image" src={src} alt="" style={{ borderRadius: radius }} onError={() => setFailed(true)} />
  ) : round ? (
    <span className="sm-avatar__face sm-avatar__face--round" style={{ background: tintFor(tintKey ?? name) }}>
      <span className="sm-avatar__initials" style={{ fontSize: g.fontSize, transform: `scale(${initialsScale(size, dot, g)})` }}>
        {initialsFor(name)}
      </span>
    </span>
  ) : (
    <span className="sm-avatar__face sm-avatar__face--square">{placeholder ?? <span className="sm-avatar__bot-initials">{initialsFor(name)}</span>}</span>
  );

  if (speaking) {
    content = (
      <SpeakingRing size={size} round={round} radius={radius}>
        {content}
      </SpeakingRing>
    );
  } else if (ringColor) {
    content = (
      <>
        {content}
        <span className="sm-avatar__ring" style={{ borderColor: ringColor, borderRadius: round ? '50%' : radius }} aria-hidden />
      </>
    );
  }

  return (
    <span
      className={['sm-avatar', className].filter(Boolean).join(' ')}
      role="img"
      aria-label={speaking ? `${name}, speaking` : name}
      style={{ width: size, height: size, ...style }}
      {...rest}
    >
      {content}
      {dot && (
        <span
          className="sm-avatar__dot"
          style={{ left: g.center - g.haloRadius, top: g.center - g.haloRadius, padding: DOT_HALO }}
        >
          {phone ? (
            <Icon name="presencePhone" size={16} width={g.mark} height={g.mark} color="var(--status-online)" />
          ) : (
            <StatusDot status={status} size={g.dot} />
          )}
        </span>
      )}
    </span>
  );
}
