# claude-statusline

A rich, 3-line status line for [Claude Code](https://claude.com/claude-code) that tracks **context/compaction**, **plan usage**, **live cost**, and **all-time tokens** — at a glance, in plain text.

```
Opus 4.8 │ myproject Context: ██████░░░░ 62% · compact at a breakpoint · Usage: Session (5h) 56% (resets in 4h6m) · Week (7d) 26%
  Spend: $8.55 session / $236.13 today / $111.27 block (2h 57m left) · Burn: $55.01/hr
  All-time — Input: 24.9M · Output: 15.1M · Cache: 3.57B (re-read context, billed ~10x cheaper) · Total: 3.61B · Cost: $2.9k (saved ~$15.4k via cache)
```

## ⚠️ Disclaimer — Use at Your Own Risk

This software is provided **"AS IS", without warranty of any kind**. You use it entirely at your own risk. It modifies files under `~/.claude/` (including `settings.json`) — **back up your config first**. All cost, token, and "savings" figures it displays are **estimates from local data and third-party tooling, NOT authoritative billing information** — never rely on them for financial decisions; check your official Anthropic billing dashboard. The author accepts **no liability** for any damages, data loss, incurred costs, or broken configurations arising from its use, and installs/relies on third-party software ([`ccusage`](https://ccusage.com), `bun`/`npm`, [GSD](https://github.com/glamcoder/gsd)) that it does not control or endorse.

**Full terms: [DISCLAIMER.md](DISCLAIMER.md). By using this software you agree to them.**

## What each line shows

**Line 1 — now**
- **Model · directory** — current model and working folder.
- **Context: `bar` NN%** — how full the context window is, color-coded to compaction urgency, with an escalating flag telling you *when to `/compact`* (see thresholds below).
- **Usage: Session (5h) / Week (7d)** — your Claude.ai Pro/Max rate-limit windows, with the 5-hour reset countdown. Color-coded by usage. *(Only shows on Pro/Max plans; absent on API/console billing.)*

**Line 2 — live cost** (requires [`ccusage`](https://ccusage.com))
- **Spend** — cost this session / today / current 5-hour billing block (with time left).
- **Burn** — current spend rate per hour.

**Line 3 — lifetime** (requires `ccusage`)
- **Input / Output / Cache** — lifetime token split. Cache reads dominate because every turn re-reads the conversation context; they're billed ~10× cheaper than fresh input.
- **Total** — all-time tokens across every session.
- **Cost** — real lifetime spend, plus an estimate of what caching saved you.

## When to compact (the context thresholds)

Color and flag escalate with raw context usage (the number `/context` shows):

| Usage | Color | Flag |
|------|-------|------|
| <50% | green | *(none)* |
| 50–70% | yellow | `compact at a breakpoint` |
| 70–85% | orange | `⚠ compact soon` |
| 85–95% | red | `🔴 compact now` |
| ~95%+ | red (blink) | `🚨 auto-compact imminent` |

Why these: Anthropic suggests proactively compacting around 50–60%; community guidance is a manual `/compact` at 70–75%; auto-compact defaults to ~95%, which fires mid-task after quality has degraded. Compacting at a natural breakpoint before then keeps you in control and produces better summaries.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/vt-gw/claude-statusline/main/setup-statusline.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/vt-gw/claude-statusline.git
cd claude-statusline
bash setup-statusline.sh
```

The installer:
1. Installs `ccusage` (via `bun` or `npm`) if it isn't already present.
2. Writes `~/.claude/hooks/merged-statusline.js`.
3. Sets `statusLine` in `~/.claude/settings.json` with `refreshInterval: 1` — **your other settings are preserved**.

Start a new Claude Code session to see it. Cost/token figures populate once the session has real API activity.

## Requirements

- **Claude Code** (status line support).
- **Node.js** — runs the status line script.
- **`bun` or `npm`** — to install `ccusage` (lines 2 & 3). Without it, lines 1 still works; cost/token lines are simply omitted.
- **[GSD](https://github.com/glamcoder/gsd)** *(optional)* — if installed, line 1 also shows your GSD milestone/phase/progress. If not, a built-in fallback shows `model │ dir` instead. Everything else is identical.

## How it works

`merged-statusline.js` reads the JSON payload Claude Code pipes to every status line render. It:
- delegates line 1 to your GSD status line (if present) and swaps GSD's context bar for the compaction-aware meter;
- runs `ccusage statusline` once per render, keeping its cost/burn segments and relabeling them as text;
- reads lifetime token/cost totals from `ccusage daily --json`, **cached for 5 minutes and refreshed in a detached background process** so the 1-second refresh never blocks.

Everything degrades gracefully: missing `ccusage`, missing GSD, or a bad payload each drop only their own segment — the status line never errors out.

## Uninstall

```bash
bash uninstall.sh
```

Removes the script and the `statusLine` entry (other settings preserved). `ccusage` is left installed.

## License

MIT
