// Builds dist/: one ESM entry, its .d.ts tree, and the stylesheet the components use.
import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';

rmSync('dist', { recursive: true, force: true });
mkdirSync('dist');
await build({
  entryPoints: ['src/index.ts'],
  outfile: 'dist/index.js',
  bundle: true,
  format: 'esm',
  jsx: 'automatic',
  target: 'es2020',
  external: ['react', 'react-dom', 'react/jsx-runtime', 'lucide-react'],
  logLevel: 'warning',
});
execFileSync('npx', ['tsc', '-p', 'tsconfig.json'], { stdio: 'inherit' });
const componentSheets = readdirSync('src/styles/components')
  .filter((name) => name.endsWith('.css'))
  .sort()
  .map((name) => `src/styles/components/${name}`);
const sheets = ['src/styles/tokens.css', 'src/styles/base.css', ...componentSheets];
writeFileSync('dist/styles.css', sheets.map((path) => readFileSync(path, 'utf8')).join('\n'));
