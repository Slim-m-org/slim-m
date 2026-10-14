import { useRef, type HTMLAttributes, type PointerEvent, type ReactNode } from 'react';
import { Icon } from './Icon';

export interface ControlWithOptionsProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** The primary control, which keeps its own press handling. */
  children: ReactNode;
  /** Opens whatever menu or sheet the caller owns. Without it the child renders untouched: no caret, no extra width. */
  onOpenOptions?: () => void;
  /** Names the caret, e.g. "Screen share options". */
  optionsLabel: string;
  /** Tints the caret to match an active primary beside it. */
  active?: boolean;
  /** Grow the caret's hit box to 44px instead of 30px. */
  touch?: boolean;
  /** The caret's drawn height in px, to match a primary that is not a full chip. */
  visualHeight?: number;
}

const LONG_PRESS_MS = 500;

/** Wraps a control and, only when onOpenOptions is set, adds a chevron caret beside it. Right-click and long-press open the same options. A joined IconButton squares its right edge to meet the caret. */
export function ControlWithOptions({
  children,
  onOpenOptions,
  optionsLabel,
  active = false,
  touch = false,
  visualHeight = 34,
  className,
  style,
  ...rest
}: ControlWithOptionsProps) {
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  if (!onOpenOptions) return <>{children}</>;

  const cancel = () => clearTimeout(timer.current);
  const start = (e: PointerEvent) => {
    if (e.pointerType === 'mouse') return;
    cancel();
    timer.current = setTimeout(onOpenOptions, LONG_PRESS_MS);
  };
  const hit = touch ? 44 : 30;

  return (
    <div
      className={['sm-control-with-options', 'sm-control-with-options--joined', className].filter(Boolean).join(' ')}
      style={style}
      onContextMenu={(e) => {
        e.preventDefault();
        onOpenOptions();
      }}
      onPointerDown={start}
      onPointerUp={cancel}
      onPointerCancel={cancel}
      onPointerLeave={cancel}
      {...rest}
    >
      {children}
      <button
        type="button"
        className={['sm-control-with-options__caret', active && 'sm-control-with-options__caret--active'].filter(Boolean).join(' ')}
        aria-label={optionsLabel}
        title={optionsLabel}
        style={{ width: hit, height: Math.max(visualHeight, hit), ['--sm-cwo-height' as string]: `${visualHeight}px` }}
        onClick={onOpenOptions}
      >
        <span className="sm-control-with-options__caret-visual">
          <Icon name="chevronDown" size={16} />
        </span>
      </button>
    </div>
  );
}
