import type { SVGAttributes } from 'react';

export interface BrandMarkProps extends Omit<SVGAttributes<SVGSVGElement>, 'color'> {
  /** Square side in px. Below 16 the dots drop and the square draws alone. */
  size?: number;
  /** Defaults to the accent, the one place brand ink comes from. Pass a colour for a mono treatment. */
  color?: string;
}

const LATTICE_FLOOR = 16;
const dots: Array<[number, number]> = [
  [9, 9],
  [21, 9],
  [9, 21],
];

/** The slim-m mark: three dots on a lattice and one rounded square that has left it. Use it as the product's logo; it is the only brand ink. */
export function BrandMark({ size = 28, color = 'var(--accent-fill)', ...rest }: BrandMarkProps) {
  const lattice = size >= LATTICE_FLOOR;
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill={color} role="img" aria-label="slim-m" {...rest}>
      {lattice ? (
        <>
          {dots.map(([cx, cy]) => (
            <circle key={`${cx}-${cy}`} cx={cx} cy={cy} r={3.2} />
          ))}
          <rect x={15} y={15} width={11} height={11} rx={3.5} />
        </>
      ) : (
        <rect x={8.472} y={8.472} width={15.056} height={15.056} rx={4.791} />
      )}
    </svg>
  );
}

export interface BrandLatticeProps extends Omit<SVGAttributes<SVGSVGElement>, 'width' | 'height'> {
  /** Panel width in px; the geometry is a function of size alone. */
  width: number;
  /** Panel height in px. */
  height: number;
}

const PITCH = 28;
const HOME_COLUMN = 4;
const HOME_ROW = 12;
const FLOOR_ALPHA = 0.06;

/** The mark's idea at page scale: a faint dot lattice fading from one accent square resting a half-step off its slot. Decorative backdrop for an onboarding rail; the square slides in once. */
export function BrandLattice({ width, height, className, ...rest }: BrandLatticeProps) {
  const columns = Math.ceil(width / PITCH) + 1;
  const rows = Math.ceil(height / PITCH) + 1;
  const homeX = HOME_COLUMN * PITCH;
  const homeY = HOME_ROW * PITCH;
  const restX = homeX + PITCH / 2;
  const restY = homeY + PITCH / 2;
  const reach = Math.min(width * 1.4, height * 0.5);
  const side = PITCH * 0.62;

  const cells = [];
  for (let c = 0; c < columns; c++) {
    for (let r = 0; r < rows; r++) {
      if (c === HOME_COLUMN && r === HOME_ROW) continue;
      const t = Math.min(1, Math.hypot(c * PITCH - restX, r * PITCH - restY) / reach);
      const alpha = 0.55 * (1 - t) * (1 - t);
      if (alpha < FLOOR_ALPHA) continue;
      cells.push(<circle key={`${c}-${r}`} cx={c * PITCH} cy={r * PITCH} r={PITCH * 0.1} fill="var(--border-strong)" fillOpacity={alpha} />);
    }
  }

  return (
    <svg
      className={['sm-brand-lattice', className].filter(Boolean).join(' ')}
      width={width}
      height={height}
      viewBox={`0 0 ${width} ${height}`}
      aria-hidden
      {...rest}
    >
      {cells}
      <rect
        className="sm-brand-lattice__square"
        x={restX - side / 2}
        y={restY - side / 2}
        width={side}
        height={side}
        rx={PITCH * 0.2}
        fill="var(--accent-fill)"
      />
    </svg>
  );
}
