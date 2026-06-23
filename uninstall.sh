#!/bin/bash
# Removes the merged statusline and restores Claude Code's default (no statusLine).
set -e
rm -f "$HOME/.claude/hooks/merged-statusline.js" && echo "Removed ~/.claude/hooks/merged-statusline.js"
node -e '
const fs=require("fs"),os=require("os"),path=require("path");
const f=path.join(os.homedir(),".claude","settings.json");
let s={}; try{ s=JSON.parse(fs.readFileSync(f,"utf8")); }catch(e){ process.exit(0); }
delete s.statusLine;
fs.writeFileSync(f,JSON.stringify(s,null,2));
console.log("Removed statusLine from ~/.claude/settings.json (other settings preserved)");
'
echo "Done. ccusage was left installed; remove it with: bun remove -g ccusage  (or npm uninstall -g ccusage)"
