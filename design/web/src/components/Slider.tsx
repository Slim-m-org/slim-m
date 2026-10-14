import { useRef, useState, type HTMLAttributes, type KeyboardEvent, type PointerEvent } from 'react';

export interface SliderProps extends Omit<HTMLAttributes<HTMLDivElement>, 'onChange' | 'defaultValue'> {
  value?: number;
  defaultValue?: number;
  onChange?: (value: number) => void;
  min?: number;
  max?: number;
  /** Keyboard and snap step; omitted means continuous with a step of 1% of the range on keys. */
  step?: number;
  /** The microphone-meter shape: a 22px trough with a 2px position line instead of a 4px round track. */
  tall?: boolean;
  /** A live input level 0-100 drawn behind the track, independent of value. */
  meter?: number;
  /** Dims the control to 50% and swaps the fill to a neutral colour. */
  muted?: boolean;
  /** Mono labels spread evenly under the track; the one nearest the thumb is picked out in accent. */
  ticks?: string[];
  disabled?: boolean;
}

const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));

/** A continuous value control: volume, threshold, text scale. Use `tall` with `meter` for the input-sensitivity meter in voice settings. */
export function Slider({
  value,
  defaultValue = 0,
  onChange,
  min = 0,
  max = 100,
  step,
  tall = false,
  meter,
  muted = false,
  ticks,
  disabled = false,
  className,
  ...rest
}: SliderProps) {
  const [inner, setInner] = useState(defaultValue);
  const [dragging, setDragging] = useState(false);
  const trackRef = useRef<HTMLDivElement>(null);
  const current = clamp(value ?? inner, min, max);
  const span = max - min;
  const fraction = span > 0 ? (current - min) / span : 0;
  const interactive = !disabled && (!!onChange || value === undefined);
  const meterFraction = meter === undefined ? undefined : clamp(meter / 100, 0, 1);
  const nearestTick = ticks && ticks.length > 1 ? Math.round(fraction * (ticks.length - 1)) : 0;

  const commit = (next: number) => {
    const snapped = step ? Math.round((next - min) / step) * step + min : next;
    const bounded = clamp(snapped, min, max);
    if (value === undefined) setInner(bounded);
    onChange?.(bounded);
  };
  const fromPointer = (event: PointerEvent) => {
    const box = trackRef.current?.getBoundingClientRect();
    if (!box || box.width === 0) return;
    commit(min + clamp((event.clientX - box.left) / box.width, 0, 1) * span);
  };
  const onKeyDown = (event: KeyboardEvent) => {
    const unit = step ?? span / 100;
    const moves: Record<string, number> = { ArrowRight: unit, ArrowUp: unit, ArrowLeft: -unit, ArrowDown: -unit, PageUp: unit * 10, PageDown: -unit * 10 };
    if (event.key === 'Home') commit(min);
    else if (event.key === 'End') commit(max);
    else if (event.key in moves) commit(current + moves[event.key]);
    else return;
    event.preventDefault();
  };

  const classes = ['sm-slider', tall && 'sm-slider--tall', muted && 'sm-slider--muted', !interactive && 'sm-slider--static', dragging && 'sm-slider--dragging', className]
    .filter(Boolean)
    .join(' ');
  return (
    <div className={classes} {...rest}>
      <div
        role="slider"
        tabIndex={interactive ? 0 : -1}
        aria-valuemin={min}
        aria-valuemax={max}
        aria-valuenow={current}
        aria-disabled={!interactive || undefined}
        className="sm-slider__hit"
        onKeyDown={interactive ? onKeyDown : undefined}
        onPointerDown={
          interactive
            ? (event) => {
                event.currentTarget.setPointerCapture(event.pointerId);
                setDragging(true);
                fromPointer(event);
              }
            : undefined
        }
        onPointerMove={interactive && dragging ? fromPointer : undefined}
        onPointerUp={() => setDragging(false)}
        onPointerCancel={() => setDragging(false)}
      >
        <div className="sm-slider__track" ref={trackRef}>
          <div className="sm-slider__clip">
            {meterFraction !== undefined && <div className="sm-slider__meter" style={{ width: `${meterFraction * 100}%` }} />}
            <div className="sm-slider__fill" style={{ ['--sm-slider-pos' as string]: `${fraction * 100}%` }} />
            <div className="sm-slider__outline" />
          </div>
          <div className="sm-slider__thumb" style={{ left: `${fraction * 100}%` }}>
            <span className="sm-slider__halo" aria-hidden />
          </div>
        </div>
      </div>
      {ticks && (
        <div className="sm-slider__ticks">
          {ticks.map((tick, i) => (
            <span key={i} className={i === nearestTick ? 'sm-slider__tick sm-slider__tick--near' : 'sm-slider__tick'}>
              {tick}
            </span>
          ))}
        </div>
      )}
    </div>
  );
}
