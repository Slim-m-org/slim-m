import { useId, useState, type InputHTMLAttributes, type ReactNode } from 'react';

export type InputSize = 'sm' | 'md' | 'lg';

export interface InputProps extends Omit<InputHTMLAttributes<HTMLInputElement>, 'size' | 'prefix'> {
  /** sm 32px, md 38px, lg 44px tall. The type size never changes. */
  size?: InputSize;
  /** Optional caption above the field; the Flutter field has none, forms usually pair one in a column. */
  label?: string;
  /** A leading glyph, already built (usually an Icon). */
  icon?: ReactNode;
  /** After the text: a shortcut hint or a clear button. */
  trailing?: ReactNode;
  /** A standing note under the field; errorText takes its place while there is one, so the form keeps its height. */
  helperText?: string;
  /** Shown under the field in the danger colour and turns the border danger. */
  errorText?: string;
  /** IBM Plex Mono, for invite codes and server addresses. */
  mono?: boolean;
  /** Grows with its text between minLines and maxLines instead of holding one line. */
  multiline?: boolean;
  minLines?: number;
  maxLines?: number;
  /** A soft limit: a count under the field turns danger when exceeded. */
  counterMax?: number;
}

const codePoints = (text: string) => Array.from(text).length;

/** A text field on the raised surface: 1px border, accent border plus a 2px accent ring on focus, danger border with error text under it in place of any helper note. */
export function Input({
  size = 'md',
  label,
  icon,
  trailing,
  helperText,
  errorText,
  mono = false,
  multiline = false,
  minLines,
  maxLines,
  counterMax,
  className,
  disabled,
  value,
  defaultValue,
  onChange,
  style,
  ...rest
}: InputProps) {
  const id = useId();
  const noteId = `${id}-note`;
  const [typed, setTyped] = useState(String(defaultValue ?? ''));
  const hasError = !!errorText;
  const grows = multiline || minLines !== undefined || maxLines !== undefined;
  const length = codePoints(value !== undefined ? String(value) : typed);
  const classes = [
    'sm-input',
    `sm-input--${size}`,
    mono && 'sm-input--mono',
    hasError && 'sm-input--error',
    disabled && 'sm-input--disabled',
    grows && 'sm-input--multiline',
    className,
  ]
    .filter(Boolean)
    .join(' ');
  const fieldProps = {
    id,
    className: 'sm-input__control',
    disabled,
    value,
    defaultValue,
    'aria-invalid': hasError || undefined,
    'aria-describedby': hasError || helperText ? noteId : undefined,
    onChange: (event: React.ChangeEvent<HTMLInputElement & HTMLTextAreaElement>) => {
      setTyped(event.target.value);
      onChange?.(event);
    },
  };
  const lineStyle = grows
    ? {
        ['--sm-input-min-lines' as string]: minLines ?? 3,
        ...(maxLines !== undefined && { ['--sm-input-max-lines' as string]: maxLines }),
      }
    : undefined;
  return (
    <div className={classes} style={{ ...lineStyle, ...style }}>
      {label && (
        <label className="sm-input__label" htmlFor={id}>
          {label}
        </label>
      )}
      <div className="sm-input__ring">
        <div className="sm-input__field">
          {icon && <span className="sm-input__icon">{icon}</span>}
          {grows ? (
            <textarea rows={minLines ?? 3} {...(rest as object)} {...fieldProps} />
          ) : (
            <input {...rest} {...fieldProps} />
          )}
          {trailing && <span className="sm-input__trailing">{trailing}</span>}
        </div>
      </div>
      {counterMax !== undefined && (
        <span className={['sm-input__counter', length > counterMax && 'sm-input__counter--over'].filter(Boolean).join(' ')}>
          {length}/{counterMax}
        </span>
      )}
      {(hasError || helperText) && (
        <span className="sm-input__beneath" id={noteId} aria-live="polite">
          {helperText && (
            <span className="sm-input__helper" aria-hidden={hasError || undefined}>
              {helperText}
            </span>
          )}
          {hasError && <span className="sm-input__error">{errorText}</span>}
        </span>
      )}
    </div>
  );
}
