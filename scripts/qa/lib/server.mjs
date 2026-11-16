// Tiny static server (no dependencies). Serves a directory on 127.0.0.1 and logs every request path it served.
import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import path from 'node:path';

const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml', '.ico': 'image/x-icon', '.txt': 'text/plain', '.woff2': 'font/woff2', '.woff': 'font/woff' };

export async function startServer(root) {
  const served = [];
  const server = http.createServer(async (req, res) => {
    try {
      const u = new URL(req.url, 'http://x');
      let rel = decodeURIComponent(u.pathname);
      if (rel.includes('\0')) throw new Error('bad path');
      let file = path.join(root, path.normalize(rel).replace(/^([/\\])+/, ''));
      if (!file.startsWith(path.resolve(root))) { res.writeHead(403).end('forbidden'); return; }
      let st = await stat(file).catch(() => null);
      if (st && st.isDirectory()) { file = path.join(file, 'index.html'); st = await stat(file).catch(() => null); }
      if (!st) { served.push({ path: u.pathname, status: 404 }); res.writeHead(404, { 'content-type': 'text/plain' }).end('not found'); return; }
      const body = await readFile(file);
      served.push({ path: u.pathname, status: 200 });
      res.writeHead(200, { 'content-type': MIME[path.extname(file).toLowerCase()] || 'application/octet-stream', 'cache-control': 'no-store' });
      res.end(req.method === 'HEAD' ? undefined : body);
    } catch (e) { res.writeHead(500).end(String(e.message || e)); }
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const { port } = server.address();
  return { url: `http://127.0.0.1:${port}/`, origin: `http://127.0.0.1:${port}`, served, close: () => new Promise((r) => { server.closeAllConnections?.(); server.close(r); }) };
}
