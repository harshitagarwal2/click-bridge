/**
 * click-bridge receiver — macOS + Windows
 *
 * Connects OUT to the relay (so no port forwarding needed on the laptop).
 * For off-network use: install Tailscale on both phone and laptop, run the
 * relay on the laptop itself (or a VPS), and point RELAY_URL at the
 * Tailscale address of the relay machine.
 *
 * Input dispatch order of operations (fastest first):
 *   1. @nut-tree-fork/libnut  — synchronous N-API native call  (<1 ms)
 *   2. osascript / PowerShell — process spawn fallback         (30–150 ms)
 * This file tries (1) and falls back to (2) automatically.
 */

import { WebSocket } from "ws";
import { execFile }  from "node:child_process";
import { platform }  from "node:os";

const RELAY_URL  = process.env.RELAY_URL;
const AUTH_TOKEN = process.env.AUTH_TOKEN;
const ACTION     = process.env.ACTION || "key:space";

if (!RELAY_URL || !AUTH_TOKEN) {
  console.error("Set RELAY_URL and AUTH_TOKEN (and optionally ACTION).");
  process.exit(1);
}

const OS = platform();

// ── Try to load the fast native input module ────────────────────────────────
let libnut = null;
try {
  const m = await import("@nut-tree-fork/libnut");
  libnut = m.default ?? m;
  console.log("Native input: @nut-tree-fork/libnut (fast path, <1 ms)");
} catch {
  console.warn("Native module not found — using process-spawn fallback (~30–150 ms).");
  console.warn("For lowest latency run:  npm install  (pulls prebuilt binary)");
}

// ── Action resolution ───────────────────────────────────────────────────────
const MAC_CODES = {
  space:49, enter:36, return:36, esc:53, escape:53, tab:48,
  up:126, down:125, left:123, right:124,
  backspace:51, delete:117, home:115, end:119, pageup:116, pagedown:121,
};
const WIN_KEYS = {
  space:" ", enter:"{ENTER}", return:"{ENTER}", esc:"{ESC}", escape:"{ESC}",
  tab:"{TAB}", up:"{UP}", down:"{DOWN}", left:"{LEFT}", right:"{RIGHT}",
  backspace:"{BACKSPACE}", delete:"{DELETE}", home:"{HOME}", end:"{END}",
  pageup:"{PGUP}", pagedown:"{PGDN}",
};

function splitAction(a) {
  if (a === "click") return ["click", null];
  const i = a.indexOf(":");
  return i === -1 ? [a, null] : [a.slice(0, i), a.slice(i + 1)];
}

const [KIND, ARG] = splitAction(ACTION);

// Pre-built fast-path fire() so the hot path does zero work per click.
let fire;

if (libnut) {
  // Fast path: synchronous N-API call, no context switch, no process.
  if (KIND === "click") {
    fire = () => libnut.mouseClick("left");
  } else if (KIND === "key") {
    const k = ARG.toLowerCase();
    // libnut uses key names like "space", "enter", "up" etc.
    fire = () => libnut.keyTap(k);
  } else if (KIND === "char") {
    fire = () => libnut.typeString(String(ARG));
  } else {
    console.error("unknown ACTION:", ACTION); process.exit(1);
  }
} else {
  // Slow fallback: spawn a process per click (~30–150 ms penalty).
  const run = (cmd, args) =>
    execFile(cmd, args, (e) => e && console.error(cmd, "failed:", e.message));

  if (OS === "darwin") {
    if (KIND === "click") {
      fire = () => run("cliclick", ["c:."]);
    } else if (KIND === "key") {
      const code = MAC_CODES[String(ARG).toLowerCase()];
      if (!code) { console.error("unknown key:", ARG); process.exit(1); }
      fire = () => run("osascript", ["-e", `tell application "System Events" to key code ${code}`]);
    } else if (KIND === "char") {
      const ch = String(ARG).replace(/["\\]/g, "");
      fire = () => run("osascript", ["-e", `tell application "System Events" to keystroke "${ch}"`]);
    }
  } else if (OS === "win32") {
    const ps = (script) => run("powershell", ["-NoProfile", "-NonInteractive", "-Command", script]);
    if (KIND === "click") {
      fire = () => ps(`Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f,int x,int y,uint d,int e);' -Name M -Namespace W;[W.M]::mouse_event(2,0,0,0,0);[W.M]::mouse_event(4,0,0,0,0)`);
    } else if (KIND === "key") {
      const tok = WIN_KEYS[String(ARG).toLowerCase()];
      if (!tok) { console.error("unknown key:", ARG); process.exit(1); }
      const safe = tok.replace(/'/g, "''");
      fire = () => ps(`Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.SendKeys]::SendWait('${safe}')`);
    } else if (KIND === "char") {
      const esc = String(ARG).replace(/[+^%~(){}\[\]]/g, (c) => `{${c}}`).replace(/'/g, "''");
      fire = () => ps(`Add-Type -AssemblyName System.Windows.Forms;[System.Windows.Forms.SendKeys]::SendWait('${esc}')`);
    }
  } else {
    console.error(`Unsupported platform "${OS}" — macOS and Windows only.`); process.exit(1);
  }
}

// ── Relay connection ─────────────────────────────────────────────────────────
let ws = null, retry = 500;

function connect() {
  const url = new URL(RELAY_URL);
  url.searchParams.set("token", AUTH_TOKEN);
  url.searchParams.set("role", "receiver");

  ws = new WebSocket(url.toString());

  ws.on("open", () => {
    retry = 500;
    console.log(`connected  OS=${OS}  ACTION=${ACTION}  input=${libnut?"native":"spawn"}`);
  });

  ws.on("message", (data) => {
    const s = data.toString();
    let t; try { t = JSON.parse(s).t; } catch { t = s === "c" ? "c" : null; }
    if (t !== "c") return;

    let at = 0; try { at = JSON.parse(s).at || 0; } catch {}
    const latency = at ? `${Date.now() - at} ms` : "?";
    console.log(`click  relay_rtt=${latency}  ACTION=${ACTION}`);
    fire();
  });

  ws.on("close", () => {
    console.log(`disconnected — retrying in ${retry} ms`);
    setTimeout(connect, retry);
    retry = Math.min(retry * 2, 10_000);
  });

  ws.on("error", (e) => console.error("ws:", e.message));
}

connect();
