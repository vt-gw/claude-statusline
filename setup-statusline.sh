#!/bin/bash
# ============================================================================
# Merged Claude Code Statusline (GSD + ccusage) — one-shot setup
# Installs ccusage, writes ~/.claude/hooks/merged-statusline.js, and wires it
# into ~/.claude/settings.json (your other settings are preserved).
# ============================================================================
set -e
echo "Setting up the merged statusline (context/compaction + usage + cost + all-time tokens)..."
echo "DISCLAIMER: provided AS IS, no warranty, use at your own risk. Modifies ~/.claude/."
echo "Cost/token figures are ESTIMATES, not authoritative billing. See DISCLAIMER.md."

# 1) ccusage provides the cost / burn / all-time token data (optional but recommended)
if command -v ccusage >/dev/null 2>&1 || [ -x "$HOME/.bun/bin/ccusage" ]; then
  echo "  ok: ccusage already installed"
elif command -v bun >/dev/null 2>&1; then
  echo "  installing ccusage via bun..."; bun install -g ccusage
elif command -v npm >/dev/null 2>&1; then
  echo "  installing ccusage via npm..."; npm install -g ccusage
else
  echo "  WARNING: need bun or npm for ccusage. Statusline still works without it (no cost/token data)."
fi

# 2) Write the statusline script
mkdir -p "$HOME/.claude/hooks"
cat > "$HOME/.claude/hooks/merged-statusline.js" <<'MERGED_STATUSLINE_EOF'
#!/usr/bin/env node
// Merged statusline: GSD-aware line 1 + ccusage cost/burn line 2.
//
// Line 1: delegates to gsd-statusline.js (model · GSD milestone/phase/todo ·
//         dir · context meter · GSD update alerts).
// Line 2: ccusage `statusline` output, with the model (🤖) and context (🧠)
//         segments stripped — those already appear on line 1 — leaving the
//         💰 cost and 🔥 burn-rate segments.
//
// Both children receive the same hook JSON on stdin (stdin is captured once
// here and replayed to each). Any failure degrades gracefully: if ccusage is
// missing or errors, only the GSD line prints; if GSD errors, only the cost
// line prints.

const { spawnSync, spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HOME = os.homedir();
const GSD_SCRIPT = path.join(HOME, '.claude', 'hooks', 'gsd-statusline.js');
const CCUSAGE_BIN = path.join(HOME, '.bun', 'bin', 'ccusage');

// Capture stdin once (statusline payload). fs.readFileSync(0) reads the pipe.
let input = '';
try {
  input = fs.readFileSync(0, 'utf8');
} catch (e) {
  // No stdin — nothing useful to render.
}

// Parse the payload for fields we render ourselves (rate-limit windows).
let payload = {};
try {
  payload = JSON.parse(input) || {};
} catch (e) {
  // Non-JSON stdin — leave payload empty; segments below just won't render.
}

// --- Session-window (rate-limit) segment ------------------------------------
// Claude.ai Pro/Max subscribers get rate_limits after the first API response:
//   rate_limits.five_hour.used_percentage  — the rolling 5-hour session block
//   rate_limits.seven_day.used_percentage  — the weekly window
// Absent on API/console billing, and null early in a session — both skip cleanly.

function colorByUsage(text, pct) {
  // green <50, yellow <80, red >=80 — matches the context-meter thresholds.
  if (pct < 50) return `\x1b[32m${text}\x1b[0m`;
  if (pct < 80) return `\x1b[33m${text}\x1b[0m`;
  return `\x1b[31m${text}\x1b[0m`;
}

function resetCountdown(resetsAt) {
  if (typeof resetsAt !== 'number') return '';
  const delta = resetsAt - Math.floor(Date.now() / 1000);
  if (delta <= 0) return '';
  const h = Math.floor(delta / 3600);
  const m = Math.floor((delta % 3600) / 60);
  return h > 0 ? `resets in ${h}h${m}m` : `resets in ${m}m`;
}

function buildSessionWindow(rl) {
  if (!rl || typeof rl !== 'object') return '';
  const parts = [];
  const fh = rl.five_hour;
  if (fh && fh.used_percentage != null) {
    const pct = Math.round(fh.used_percentage);
    const reset = resetCountdown(fh.resets_at);
    const seg = `Session (5h) ${pct}%${reset ? ' (' + reset + ')' : ''}`;
    parts.push(colorByUsage(seg, pct));
  }
  const sd = rl.seven_day;
  if (sd && sd.used_percentage != null) {
    const pct = Math.round(sd.used_percentage);
    parts.push(colorByUsage(`Week (7d) ${pct}%`, pct));
  }
  return parts.length ? parts.join('  ·  ') : '';
}

const sessionWindow = buildSessionWindow(payload.rate_limits);

// --- Context / compaction meter (research-tuned) ----------------------------
// Raw context usage = context_window.used_percentage — the number `/context`
// shows and the figure all compaction guidance is expressed in. Zones reflect
// Anthropic + community guidance:
//   <50%  comfortable · 50-70% proactive sweet spot (compact at a breakpoint)
//   70-85% late · 85-95% quality degrades · ~95% auto-compact fires mid-task.
function buildContextMeter(cw) {
  if (!cw || typeof cw !== 'object') return null;
  let used = cw.used_percentage;
  if (used == null && cw.remaining_percentage != null) used = 100 - cw.remaining_percentage;
  if (used == null) return null;
  const pct = Math.max(0, Math.min(100, Math.round(used)));
  const filled = Math.round(pct / 10);
  const bar = '█'.repeat(filled) + '░'.repeat(10 - filled);

  let color, flag;
  if (pct < 50)      { color = '32';      flag = ''; }                            // green
  else if (pct < 70) { color = '33';      flag = ' · compact at a breakpoint'; }  // yellow
  else if (pct < 85) { color = '38;5;208';flag = ' · ⚠ compact soon'; }           // orange
  else if (pct < 95) { color = '31';      flag = ' · 🔴 compact now'; }           // red
  else               { color = '5;31';    flag = ' · 🚨 auto-compact imminent'; } // red blink

  return `\x1b[${color}mContext: ${bar} ${pct}%${flag}\x1b[0m`;
}
const contextMeter = buildContextMeter(payload.context_window);

// Strip GSD's own context bar from line 1 when we render our own, so there's a
// single context readout (GSD's is normalized to the auto-compact buffer; ours
// is the raw /context number the compaction zones above are based on).
function stripGsdContextBar(line) {
  // GSD appends: " <ESC>[<codes>m[💀 ]<bar> NN%<ESC>[0m" (bar = █/░ runs).
  return line.replace(/\s*\x1b\[[0-9;]*m(?:💀 )?[█░]+ \d+%\x1b\[0m/g, '');
}

// --- All-time token counter (cached, refreshed in background) ---------------
// `ccusage daily --json` totals.totalTokens is the lifetime token count, but it
// takes ~0.5s — far too slow to run on every 1s refresh. So we read a cached
// value and, when it's stale, kick off a DETACHED background refresh that never
// blocks this render. The next render picks up the freshly-written value.
const TOTAL_CACHE = path.join(os.tmpdir(), 'ccusage-alltime-tokens.json');
const TOTAL_LOCK = path.join(os.tmpdir(), 'ccusage-alltime-tokens.lock');
const TOTAL_TTL_MS = 5 * 60 * 1000; // all-time count drifts slowly; 5-min staleness is invisible
const LOCK_MS = 30 * 1000;          // throttle: at most one background refresh per 30s

function fmtTokens(n) {
  if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'k';
  return String(n);
}

function fmtMoney(n) {
  if (n >= 1000) return '$' + (n / 1000).toFixed(1) + 'k';
  if (n >= 100) return '$' + n.toFixed(0);
  return '$' + n.toFixed(2);
}

function refreshAllTimeTokens(ccusagePath) {
  // Throttle via a lock file so overlapping 1s renders don't spawn a storm.
  try {
    const lk = fs.statSync(TOTAL_LOCK);
    if (Date.now() - lk.mtimeMs < LOCK_MS) return; // a refresh ran recently
  } catch (e) { /* no lock yet — proceed */ }
  try { fs.writeFileSync(TOTAL_LOCK, String(Date.now())); } catch (e) {}

  // Detached child: run ccusage synchronously, write the token breakdown to the
  // cache, then exit. unref() lets this statusline process exit immediately.
  const refresher =
    'const cp=require("child_process"),fs=require("fs");try{' +
    'const out=cp.execFileSync(' + JSON.stringify(ccusagePath) + ',["daily","--json"],{encoding:"utf8",maxBuffer:1e8});' +
    'const t=JSON.parse(out).totals;' +
    'fs.writeFileSync(' + JSON.stringify(TOTAL_CACHE) + ',JSON.stringify({' +
    'tokens:t.totalTokens,input:t.inputTokens,output:t.outputTokens,' +
    'cache:(t.cacheCreationTokens||0)+(t.cacheReadTokens||0),cost:t.totalCost,ts:Date.now()}));' +
    '}catch(e){}';
  try {
    const child = spawn(process.execPath, ['-e', refresher], { detached: true, stdio: 'ignore' });
    child.unref();
  } catch (e) {}
}

let allTimeStr = '';
{
  let cache = null;
  try { cache = JSON.parse(fs.readFileSync(TOTAL_CACHE, 'utf8')); } catch (e) {}
  if (cache && typeof cache.tokens === 'number') {
    // Lead with the input/output split; show cache + total so the numbers
    // reconcile (the all-time total is overwhelmingly cache-read tokens).
    const split = (typeof cache.input === 'number' && typeof cache.output === 'number')
      ? `Input: ${fmtTokens(cache.input)} · Output: ${fmtTokens(cache.output)}`
      : '';
    const cacheSeg = typeof cache.cache === 'number'
      ? ` · Cache: ${fmtTokens(cache.cache)} (re-read context, billed ~10x cheaper)`
      : '';

    // Cost + cache-savings estimate. Counterfactual "no caching": the cache
    // tokens would have been billed as fresh input. Approximated at Opus 4.8
    // standard rates ($5/M input, $25/M output) — a rough upper bound, since
    // any Sonnet/Haiku usage in the mix is cheaper. Labelled "~".
    const IN_RATE = 5 / 1e6, OUT_RATE = 25 / 1e6;
    let costSeg = '';
    if (typeof cache.cost === 'number') {
      costSeg = ` · Cost: ${fmtMoney(cache.cost)}`;
      if (typeof cache.input === 'number' && typeof cache.output === 'number' && typeof cache.cache === 'number') {
        const noCache = (cache.input + cache.cache) * IN_RATE + cache.output * OUT_RATE;
        const saved = noCache - cache.cost;
        if (saved > 0) costSeg += ` (saved ~${fmtMoney(saved)} via cache)`;
      }
    }

    allTimeStr = split
      ? `All-time — ${split}${cacheSeg} · Total: ${fmtTokens(cache.tokens)}${costSeg}`
      : `All-time — Total: ${fmtTokens(cache.tokens)}${costSeg}`;
  }
  // Trigger a background refresh when missing or stale (non-blocking).
  if (!cache || typeof cache.ts !== 'number' || Date.now() - cache.ts > TOTAL_TTL_MS) {
    const ccusagePath = fs.existsSync(CCUSAGE_BIN) ? CCUSAGE_BIN : 'ccusage';
    refreshAllTimeTokens(ccusagePath);
  }
}

// --- Line 1: GSD statusline --------------------------------------------------
let gsdLine = '';
try {
  const r = spawnSync(process.execPath, [GSD_SCRIPT], {
    input,
    encoding: 'utf8',
    timeout: 3000,
  });
  gsdLine = (r.stdout || '').replace(/\r?\n+$/, '');
} catch (e) {
  // GSD line is best-effort.
}

// --- Line 2: ccusage cost/burn ----------------------------------------------
let costLine = '';
try {
  const ccusagePath = fs.existsSync(CCUSAGE_BIN) ? CCUSAGE_BIN : 'ccusage';
  const r = spawnSync(ccusagePath, ['statusline', '--visual-burn-rate', 'off'], {
    input,
    encoding: 'utf8',
    timeout: 3000,
  });
  let out = (r.stdout || '').replace(/\r?\n+$/, '').trim();
  // ccusage prints errors to stderr (exit 0 with empty stdout on bad input),
  // so an empty/short stdout simply yields no cost line.
  if (out && r.status === 0) {
    // Segments are " | "-separated: 🤖 model | 💰 cost | 🔥 burn | 🧠 context.
    // Drop model + context (already on line 1); relabel the rest as text and
    // strip ccusage's emojis so the whole statusline is emoji-free.
    const kept = out
      .split(' | ')
      .map(s => s.trim())
      .filter(s => s && !s.includes('🤖') && !s.includes('🧠'))
      .map(s => s
        .replace('💰', 'Spend:')
        .replace('🔥', 'Burn:')
        .replace(/[🚨🟢🟡🔴]/gu, '')
        .replace(/\s{2,}/g, ' ')
        .trim());
    if (kept.length) costLine = kept.join('  ·  ');
  }
} catch (e) {
  // ccusage is optional — degrade to GSD-only.
}

// --- Compose -----------------------------------------------------------------
// Line 1 (now): GSD output with its context bar swapped for our compaction-aware
// meter, plus the plan-usage windows (session/week, color-coded by usage).
let line1 = gsdLine;
if (!line1) {
  // Standalone fallback when the GSD statusline isn't installed: synthesize a
  // minimal "model │ dir" prefix from the payload so this works on any machine.
  const m = payload.model && payload.model.display_name ? payload.model.display_name : 'Claude';
  const d = payload.workspace && payload.workspace.current_dir ? payload.workspace.current_dir : '';
  const base = d ? path.basename(d) : '';
  line1 = `\x1b[2m${m}\x1b[0m${base ? ` │ \x1b[2m${base}\x1b[0m` : ''}`;
}
if (contextMeter) line1 = stripGsdContextBar(line1) + ` ${contextMeter}`;
if (sessionWindow) line1 += `  ·  Usage: ${sessionWindow}`;

// Line 2 (live cost): session spend + burn rate from ccusage (dimmed).
// Line 3 (lifetime): all-time token breakdown + cost + cache savings (dimmed).
const lines = [line1];
if (costLine) lines.push(`  \x1b[2m${costLine}\x1b[0m`);
if (allTimeStr) lines.push(`  \x1b[2m${allTimeStr}\x1b[0m`);

process.stdout.write(lines.filter(Boolean).join('\n'));
MERGED_STATUSLINE_EOF
echo "  ok: wrote ~/.claude/hooks/merged-statusline.js"

# 3) Configure settings.json (reads existing, sets statusLine, writes back)
node -e '
const fs=require("fs"),os=require("os"),path=require("path");
const f=path.join(os.homedir(),".claude","settings.json");
let s={}; try{ s=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){}
s.statusLine={type:"command",command:"node \""+path.join(os.homedir(),".claude","hooks","merged-statusline.js")+"\"",refreshInterval:1};
fs.mkdirSync(path.dirname(f),{recursive:true});
fs.writeFileSync(f,JSON.stringify(s,null,2));
console.log("  ok: configured statusLine in ~/.claude/settings.json");
'
echo ""
echo "Done. Start a new Claude Code session to see it."
echo "Cost/token figures populate from ccusage once the session has real activity."
