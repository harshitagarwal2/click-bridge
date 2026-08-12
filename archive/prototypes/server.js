/**
 * click-bridge  —  internet relay (runs on a cloud VPS / Fly.io)
 *
 * Latency contributions on this path:
 *   Internet RTT phone→relay         ~20–80 ms  (geography, ISP — biggest lever)
 *   Internet RTT relay→laptop        ~20–80 ms  (geography, ISP)
 *   Tailscale direct WireGuard       ~0.8 ms    (when direct path holds)
 *   Tailscale DERP relay penalty     +18–45 ms  (falls back ~5% of connections)
 *   TCP Nagle disabled here          0 ms       (was up to ~40 ms tail)
 *   In-process input (receiver.js)   <1 ms      (was 30–150 ms per spawn)
 *   pointerdown on phone             0 ms       (saves 10–80 ms vs click event)
 *   WiFi radio keep-warm ping        0 ms       (prevents 50–150 ms first-tap spike)
 *
 * Transport decision: plain WebSocket (not WebRTC DataChannel, not WebTransport).
 *   - WebRTC DataChannel: 200–400 ms ICE setup per connect, SCTP overhead,
 *     TURN server cost; only wins under sustained packet loss which doesn't
 *     apply to rare single-click events.
 *   - WebTransport/QUIC: better under loss but iOS Safari support is absent.
 *   - WebSocket + TCP_NODELAY is simpler, universally supported, and equally
 *     fast for this traffic shape (one tiny packet per click, no streams).
 *
 * Relay placement is the single most impactful variable. Pick a Fly.io/Render
 * region geographically close to both devices. Same-city = 1–5 ms relay hop.
 * Wrong continent = 80–150 ms relay hop.
 */

import http from "node:http";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { WebSocketServer, WebSocket } from "ws";

const PORT  = Number(process.env.PORT  || 8080);
const TOKEN = process.env.AUTH_TOKEN   || "";

if (!TOKEN || TOKEN.length < 16) {
  console.error("AUTH_TOKEN must be set and at least 16 characters.");
  process.exit(1);
}

const __dir = dirname(fileURLToPath(import.meta.url));
const page  = readFileSync(join(__dir, "public", "index.html"));

const server = http.createServer((req, res) => {
  const path = (req.url || "/").split("?")[0];
  if (path === "/")             { res.writeHead(200, { "content-type": "text/html; charset=utf-8" }); res.end(page); }
  else if (path === "/healthz") { res.writeHead(200, { "content-type": "text/plain" }); res.end("ok"); }
  else                          { res.writeHead(404); res.end(); }
});

// Disable Nagle on every TCP socket — removes up to ~40 ms batching tail latency.
server.on("connection", (s) => s.setNoDelay(true));

const wss       = new WebSocketServer({ noServer: true });
const receivers = new Set();

server.on("upgrade", (req, socket, head) => {
  const url  = new URL(req.url, `http://${req.headers.host}`);
  const role = url.searchParams.get("role") === "receiver" ? "receiver" : "sender";

  if (url.searchParams.get("token") !== TOKEN) {
    socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
    socket.destroy();
    return;
  }

  wss.handleUpgrade(req, socket, head, (ws) => {
    ws.isAlive = true;
    ws.on("pong", () => { ws.isAlive = true; });

    if (role === "receiver") {
      receivers.add(ws);
      console.log(`[+] receiver  total=${receivers.size}`);
      ws.on("close", () => { receivers.delete(ws); console.log(`[-] receiver  total=${receivers.size}`); });
      return;
    }

    // sender path
    ws.on("message", (data) => {
      const s = data.toString();
      // Bare "c" = smallest possible click signal; skip JSON entirely.
      const isClick = s === "c" || (s.includes('"t"') && s.includes('"c"'));
      if (!isClick) return;

      let at = 0;
      try { at = JSON.parse(s).at || 0; } catch {}

      let n = 0;
      for (const r of receivers) {
        if (r.readyState === WebSocket.OPEN) {
          r.send(at ? `{"t":"c","at":${at}}` : '{"t":"c"}');
          n++;
        }
      }
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(at ? `{"t":"a","at":${at},"n":${n}}` : `{"t":"a","n":${n}}`);
      }
    });
  });
});

// 25-second heartbeat keeps connections alive through proxy/host idle timeouts.
const hb = setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 25_000);
wss.on("close", () => clearInterval(hb));

server.listen(PORT, () => console.log(`click-bridge relay :${PORT}`));
