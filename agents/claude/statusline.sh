#!/usr/bin/env bash
# Claude Code StatusLine (bash port of statusline.ps1, full-feature)
# Reads Claude Code statusline JSON from stdin; prints a single status line.

set -u

# ---------- read stdin ----------
raw="$(cat 2>/dev/null || true)"
if [ -z "${raw//[[:space:]]/}" ]; then
  printf 'Claude'
  exit 0
fi

have_jq=0
if command -v jq >/dev/null 2>&1; then have_jq=1; fi

# jget <jq-filter> [default] — extract a value via jq, fall back to default
jget() {
  local filter="$1" def="${2:-}"
  if [ "$have_jq" -eq 1 ]; then
    local v
    v="$(printf '%s' "$raw" | jq -r "$filter // empty" 2>/dev/null)"
    if [ -n "$v" ] && [ "$v" != "null" ]; then printf '%s' "$v"; return; fi
  fi
  printf '%s' "$def"
}

# If jq is unavailable we can't parse; degrade to model-less label.
if [ "$have_jq" -ne 1 ]; then
  printf 'Claude'
  exit 0
fi

# ---------- helpers ----------
format_token() {  # k / M formatting; empty when 0/empty
  local n="${1:-0}"
  [ -z "$n" ] && return
  awk -v n="$n" 'BEGIN{
    if (n+0 <= 0) { exit }
    if (n+0 >= 1000000) printf "%.1fM", n/1000000;
    else if (n+0 >= 1000) printf "%.0fk", n/1000;
    else printf "%d", n;
  }'
}

# ---------- extract fields (Claude Code schema) ----------
model="$(jget '.model.display_name' "$(jget '.model.id' 'Claude')")"

cwd="$(jget '.workspace.current_dir' "$(jget '.cwd' "$PWD")")"
project="${cwd##*/}"; project="${project##*\\}"
[ -z "$project" ] && project="-"

dur_ms="$(jget '.cost.total_duration_ms' 0)"
# Format duration as compact d/h/m/s, dropping leading zero units (e.g. 9012s -> 2h30m12s)
dur_human=$(awk -v ms="$dur_ms" 'BEGIN{
  s = int(ms/1000);
  d = int(s/86400); s -= d*86400;
  h = int(s/3600);  s -= h*3600;
  m = int(s/60);    s -= m*60;
  out = "";
  if (d > 0) out = out d "d";
  if (h > 0 || d > 0) out = out h "h";
  if (m > 0 || h > 0 || d > 0) out = out m "m";
  out = out s "s";
  printf "%s", out;
}')

cost="$(jget '.cost.total_cost_usd' '')"

# Context %: prefer pre-calculated, else compute from tokens
ctx_pct="$(jget '.context_window.used_percentage' '')"
in_tok="$(jget '.context_window.total_input_tokens' 0)"
out_tok="$(jget '.context_window.total_output_tokens' 0)"
ctx_size="$(jget '.context_window.context_window_size' 200000)"
if [ -n "$ctx_pct" ]; then
  ctx_pct=$(awk -v p="$ctx_pct" 'BEGIN{printf "%d", int(p)}')
else
  ctx_pct=$(awk -v i="$in_tok" -v o="$out_tok" -v s="$ctx_size" 'BEGIN{
    if (s>0 && (i+o)>0) printf "%d", int(((i+o)*100.0)/s); else print ""
  }')
fi

# Session tokens = in-context input + output
tokens=$(awk -v i="$in_tok" -v o="$out_tok" 'BEGIN{printf "%d", i+o}')

# Rate limits (Pro/Max only, may be absent)
five_hour="$(jget '.rate_limits.five_hour.used_percentage' '')"
seven_day="$(jget '.rate_limits.seven_day.used_percentage' '')"
reset_ts="$(jget '.rate_limits.five_hour.resets_at' '')"

# ---------- ccusage: historical cost (today / last 7d / all-time) ----------
# ccusage --json returns { daily:[{period:"YYYY-MM-DD", totalCost, ...}], totals:{totalCost} }.
# Session cost (.cost.total_cost_usd) resets each session; ccusage aggregates across all sessions.
cost_today=""; cost_week=""; cost_total=""
if command -v ccusage >/dev/null 2>&1; then
  cc_raw="$(ccusage --json 2>/dev/null || true)"
  if [ -n "${cc_raw//[[:space:]]/}" ]; then
    today="$(date +%Y-%m-%d)"
    cut7="$(date -d '6 days ago' +%Y-%m-%d 2>/dev/null || true)"   # 7-day window incl. today
    cost_today="$(printf '%s' "$cc_raw" | jq -r --arg t "$today" '[.daily[]|select(.period==$t)|.totalCost]|add // 0' 2>/dev/null)"
    [ -n "$cut7" ] && cost_week="$(printf '%s' "$cc_raw" | jq -r --arg c "$cut7" '[.daily[]|select(.period>=$c)|.totalCost]|add // 0' 2>/dev/null)"
    cost_total="$(printf '%s' "$cc_raw" | jq -r '.totals.totalCost // 0' 2>/dev/null)"
  fi
fi

# ---------- ANSI colors ----------
E=$'\033'
R="${E}[0m"; GRAY="${E}[90m"; CYAN="${E}[36m"; MAG="${E}[35m"
GREEN="${E}[32m"; BLUE="${E}[34m"; YELLOW="${E}[33m"; RED="${E}[31m"

ctxC=""
if [ -n "$ctx_pct" ]; then
  if   [ "$ctx_pct" -ge 90 ] 2>/dev/null; then ctxC="$RED"
  elif [ "$ctx_pct" -ge 80 ] 2>/dev/null; then ctxC="$YELLOW"
  else ctxC="$GREEN"; fi
fi

# ---------- compose ----------
parts=()
parts+=("🧠 ${dur_human}")
parts+=("${CYAN}${model}${R}")
parts+=("${MAG}${project}${R}")

tok_txt="$(format_token "$tokens")"
if [ -n "$tok_txt" ]; then
  if [ "${tokens:-0}" -ge 500000 ] 2>/dev/null; then
    parts+=("sess:${tok_txt} ${RED}WARN${R}")
  else
    parts+=("sess:${tok_txt}")
  fi
fi

[ -n "$ctx_pct" ] && parts+=("${ctxC}ctx:${ctx_pct}%${R}")

# Cost: sess (this session, always) | d | 7d | total (last three from ccusage when available)
cs="$(awk -v c="${cost:-0}" 'BEGIN{printf "%.2f", c+0}')"
cost_seg="sess:${GREEN}\$${cs}${R}"
if [ -n "$cost_total" ]; then
  ct="$(awk -v c="${cost_today:-0}" 'BEGIN{printf "%.2f", c+0}')"
  cw="$(awk -v c="${cost_week:-0}"  'BEGIN{printf "%.2f", c+0}')"
  ca="$(awk -v c="${cost_total:-0}" 'BEGIN{printf "%.2f", c+0}')"
  cost_seg="${cost_seg}${GRAY} | ${R}d:${GREEN}\$${ct}${R}${GRAY} | ${R}7d:${GREEN}\$${cw}${R}${GRAY} | ${R}total:${GREEN}\$${ca}${R}"
fi
parts+=("$cost_seg")

if [ -n "$five_hour" ]; then
  p5="$(awk -v p="$five_hour" 'BEGIN{printf "%d", p+0.5}')"
  parts+=("${BLUE}5h:${p5}%${R}")
fi
if [ -n "$seven_day" ]; then
  p7="$(awk -v p="$seven_day" 'BEGIN{printf "%d", p+0.5}')"
  parts+=("${BLUE}7d:${p7}%${R}")
fi

if [ -n "$reset_ts" ]; then
  reset_local="$(date -d "@${reset_ts}" '+%H:%M' 2>/dev/null || true)"
  [ -n "$reset_local" ] && parts+=("${GRAY}↻${reset_local}${R}")
fi

# join with " | "
sep=" ${GRAY}|${R} "
out=""
for i in "${!parts[@]}"; do
  if [ "$i" -eq 0 ]; then out="${parts[$i]}"; else out="${out}${sep}${parts[$i]}"; fi
done
printf '%s' "$out"
