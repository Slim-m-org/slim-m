import type { HTMLAttributes, ReactNode } from 'react';

export interface SpeakingRingProps extends HTMLAttributes<HTMLSpanElement> {
  children: ReactNode;
  /** Side of the square child, which the reduced-motion glyph is scaled from. */
  size: number;
  /** Circle (default) or rounded rectangle, matching the child's shape. */
  round?: boolean;
  /** Corner radius in px when not round. */
  radius?: number;
  /** Ring colour. Defaults to the accent. */
  color?: string;
  /** Backdrop of the reduced-motion glyph. Defaults to the base surface. */
  glyphBackgroundColor?: string;
}

/** The speaking ring: a 2px accent ring pulsing at 600ms around its child. Under reduced motion it holds still and gains a bar glyph. Mount only while someone is speaking. */
export function SpeakingRing({
  children,
  size,
  round = true,
  radius = 6,
  color,
  glyphBackgroundColor,
  className,
  style,
  ...rest
}: SpeakingRingProps) {
  const glyph = Math.max(9, Math.round(size * 0.3));
  const bars = [0.5, 1, 0.7];
  const barWidth = glyph * 0.18;
  const gap = glyph * 0.14;
  const total = bars.length * barWidth + (bars.length - 1) * gap;
  return (
    <span
      className={['sm-speaking-ring', className].filter(Boolean).join(' ')}
      style={{
        width: size,
        height: size,
        ['--sm-speaking-color' as string]: color ?? 'var(--accent-fill)',
        ['--sm-speaking-bg' as string]: glyphBackgroundColor ?? 'var(--surface-base)',
        ...style,
      }}
      {...rest}
    >
      {children}
      <span className="sm-speaking-ring__ring" style={{ borderRadius: round ? '50%' : radius }} aria-hidden />
      <span className="sm-speaking-ring__glyph" aria-hidden>
        <svg width={glyph} height={glyph} viewBox={`0 0 ${glyph} ${glyph}`}>
          {bars.map((fraction, i) => {
            const h = glyph * fraction;
            return (
              <rect key={i} x={(glyph - total) / 2 + i * (barWidth + gap)} y={(glyph - h) / 2} width={barWidth} height={h} rx={barWidth / 2} fill="currentColor" />
            );
          })}
        </svg>
      </span>
    </span>
  );
}
