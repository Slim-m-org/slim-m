import { useState, type HTMLAttributes, type ReactNode } from 'react';

export type CodeRole = 'keyword' | 'string' | 'number' | 'comment' | 'punctuation' | 'plain' | 'hidden';
export interface CodeSpan {
  text: string;
  role?: CodeRole;
}
export type CodeLine = CodeSpan[];

export interface CodeBlockProps extends Omit<HTMLAttributes<HTMLDivElement>, 'children'> {
  /** Pre-classified lines. Takes precedence over `code`. */
  lines?: CodeLine[];
  /** Raw source; run through a tiny keyword/string/number/comment highlighter. */
  code?: string;
  /** Shown in the header, in mono. The header renders even when empty. */
  language?: string;
  /** Header slot at the end, typically a Run or Copy button. */
  action?: ReactNode;
  /** A band between header and body for a warning the reader must see first. */
  notice?: ReactNode;
  /** Folds a longer block to this many lines behind a "Show more" bar. */
  collapseAfterLines?: number;
}

const KEYWORDS = new Set(
  'const let var function return if else for while class import export from new async await fn pub struct enum impl use mut match true false null undefined def self in of try catch throw switch case break continue type interface'.split(' '),
);
const TOKEN = /(\/\/.*|#.*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)|(\b\d+(?:\.\d+)?\b)|([A-Za-z_]\w*)|([{}()[\];,.:<>=+\-*/!&|?]+)|(\s+|.)/g;

/** Classifies one line; deliberately shallow, enough to colour a mock. */
export function highlightLine(line: string): CodeLine {
  const spans: CodeSpan[] = [];
  for (const m of line.matchAll(TOKEN)) {
    const [text, comment, str, num, word, punct] = m;
    const role: CodeRole = comment ? 'comment' : str ? 'string' : num ? 'number' : word ? (KEYWORDS.has(word) ? 'keyword' : 'plain') : punct ? 'punctuation' : 'plain';
    spans.push({ text, role });
  }
  return spans;
}

/** A fenced code block: raised mono panel with a language header, optional action and notice, and optional fold. Colours come from the theme-aware code tokens. */
export function CodeBlock({ lines, code, language, action, notice, collapseAfterLines, className, ...rest }: CodeBlockProps) {
  const [expanded, setExpanded] = useState(false);
  const all = lines ?? (code ?? '').split('\n').map(highlightLine);
  const collapsible = collapseAfterLines != null && all.length > collapseAfterLines;
  const visible = collapsible && !expanded ? all.slice(0, collapseAfterLines) : all;
  const hidden = collapsible ? all.length - collapseAfterLines : 0;
  return (
    <div className={['sm-codeblock', className].filter(Boolean).join(' ')} {...rest}>
      <div className="sm-codeblock__header">
        <span className="sm-codeblock__lang">{language ?? ''}</span>
        {action}
      </div>
      {notice && <div className="sm-codeblock__notice">{notice}</div>}
      <pre className="sm-codeblock__body">
        {visible.map((line, i) => (
          <span key={i}>
            {i > 0 && '\n'}
            {line.map((s, j) => (
              <span key={j} className={`sm-code--${s.role ?? 'plain'}`}>
                {s.text}
              </span>
            ))}
          </span>
        ))}
      </pre>
      {collapsible && (
        <button type="button" className="sm-codeblock__toggle" onClick={() => setExpanded(!expanded)}>
          {expanded ? 'Show less' : `Show ${hidden} more ${hidden === 1 ? 'line' : 'lines'}`}
        </button>
      )}
    </div>
  );
}

export interface InlineCodeProps extends HTMLAttributes<HTMLElement> {
  children?: ReactNode;
}

/** A short code run inside message text; a raised chip, the opposite of the recessed block. */
export function InlineCode({ className, children, ...rest }: InlineCodeProps) {
  return (
    <code className={['sm-inline-code', className].filter(Boolean).join(' ')} {...rest}>
      {children}
    </code>
  );
}
