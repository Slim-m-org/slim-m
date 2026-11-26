// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import http, { type IncomingMessage } from 'node:http';
import https from 'node:https';
import type { Duplex } from 'node:stream';
import path from 'node:path';
import { repoRoot, workDir, type Stack } from './stack';

/**
 * The stack behind one https origin, as a deployment serves it.
 *
 * The web client keeps its sign-in in a Secure, SameSite=Strict cookie that only travels to the page's own
 * origin, and it only does so over https (decision 0141). Served from two http ports a browser tab would
 * never hold a session, so the suite reaches the web build and the server through this one TLS front.
 */
export interface SecureFront {
  origin: string;
  close(): Promise<void>;
}

let running: SecureFront | undefined;

export async function stopSecureFront(): Promise<void> {
  await running?.close();
  running = undefined;
}

const LOOPBACK = '127.0.0.1';

export function webBundleDir(): string {
  return process.env.E2E_WEB_DIR ?? path.join(repoRoot, 'client', 'packages', 'app', 'build', 'web');
}

function selfSignedCertificate(): { key: string; cert: string } {
  const keyFile = path.join(workDir(), 'front-key.pem');
  const certFile = path.join(workDir(), 'front-cert.pem');
  execFileSync(
    'openssl',
    ['req', '-x509', '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1', '-nodes', '-days', '2',
      '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1', '-keyout', keyFile, '-out', certFile],
    { stdio: 'ignore' },
  );
  return { key: readFileSync(keyFile, 'utf8'), cert: readFileSync(certFile, 'utf8') };
}

/** Whether the web build, rather than the API, answers this path. */
export function isWebPath(requestUrl: string, bundle: string): boolean {
  const pathname = decodeURIComponent(new URL(requestUrl, 'http://front').pathname);
  if (pathname === '/' || pathname.startsWith('/__e2e/')) return true;
  const file = path.resolve(bundle, `.${pathname}`);
  return file.startsWith(bundle + path.sep) && existsSync(file) && statSync(file).isFile();
}

function portOf(url: string): number {
  return Number(new URL(url).port);
}

function relay(req: IncomingMessage, port: number, onResponse: (res: IncomingMessage) => void, onError: () => void) {
  const upstream = http.request(
    { host: LOOPBACK, port, method: req.method, path: req.url, headers: req.headers },
    onResponse,
  );
  upstream.on('error', onError);
  return upstream;
}

/** Starts the TLS front on a free loopback port and records its origin for the suite's workers. */
export async function startSecureFront(stack: Stack): Promise<SecureFront> {
  const bundle = path.resolve(webBundleDir());
  const [apiPort, webPort] = [portOf(stack.api), portOf(stack.web)];
  const portFor = (url: string) => (isWebPath(url, bundle) ? webPort : apiPort);

  const server = https.createServer(selfSignedCertificate(), (req, res) => {
    const upstream = relay(
      req,
      portFor(req.url ?? '/'),
      (answer) => {
        res.writeHead(answer.statusCode ?? 502, answer.headers);
        answer.pipe(res);
      },
      () => res.destroy(),
    );
    req.pipe(upstream);
  });

  server.on('upgrade', (req: IncomingMessage, client: Duplex, head: Buffer) => {
    const upstream = http.request({ host: LOOPBACK, port: portFor(req.url ?? '/'), method: req.method, path: req.url, headers: req.headers });
    upstream.on('upgrade', (answer, socket, upstreamHead) => {
      const lines = Object.entries(answer.headers).flatMap(([name, value]) =>
        (Array.isArray(value) ? value : [value ?? '']).map((one) => `${name}: ${one}`),
      );
      client.write(`HTTP/1.1 101 Switching Protocols\r\n${lines.join('\r\n')}\r\n\r\n`);
      if (upstreamHead.length) client.write(upstreamHead);
      socket.pipe(client).pipe(socket);
      socket.on('error', () => client.destroy());
      client.on('error', () => socket.destroy());
    });
    upstream.on('error', () => client.destroy());
    upstream.end(head);
  });

  await new Promise<void>((resolve) => server.listen(0, LOOPBACK, resolve));
  const origin = `https://${LOOPBACK}:${(server.address() as { port: number }).port}`;
  writeFileSync(path.join(workDir(), 'secure-origin.txt'), origin);
  running = {
    origin,
    close: () => new Promise<void>((resolve) => {
      server.closeAllConnections();
      server.close(() => resolve());
    }),
  };
  return running;
}
