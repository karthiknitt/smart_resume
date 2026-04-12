#!/bin/zsh
input=$(cat)

# ---------------------------------------------------------------------------
# Gruvbox 256-colour palette (matches starship.toml)
# ---------------------------------------------------------------------------
# color_orange=208  color_yellow=214  color_aqua=43   color_blue=68
# color_bg3=238     color_bg1=237     color_fg0=230   color_red=196
# color_green=40

fg()  { printf "\e[38;5;%sm" "$1"; }
reset() { printf "\e[0m"; }

C_ORANGE=$(fg 208)
C_YELLOW=$(fg 214)
C_AQUA=$(fg 43)
C_BLUE=$(fg 68)
C_BG3=$(fg 238)
C_FG2=$(fg 250)
C_FG0=$(fg 230)
C_RED=$(fg 196)
C_GREEN=$(fg 40)
C_RESET=$(reset)

# ---------------------------------------------------------------------------
# Extract JSON fields
# ---------------------------------------------------------------------------
cwd=$(echo "$input"           | jq -r '.workspace.current_dir')
input_tokens=$(echo "$input"  | jq -r '.context_window.current_usage.input_tokens // 0')
cache_creation=$(echo "$input"| jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
cache_read=$(echo "$input"    | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
context_window_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
model_name=$(echo "$input"    | jq -r '.model.display_name // empty')
version=$(echo "$input"       | jq -r '.version // empty')
output_style=$(echo "$input"  | jq -r '.output_style.name // empty')
session_cost=$(echo "$input"  | jq -r '.cost.total_cost_usd // empty')
rl_5h_pct=$(echo "$input"     | jq -r '.rate_limits.five_hour.used_percentage // empty')
rl_7d_pct=$(echo "$input"     | jq -r '.rate_limits.seven_day.used_percentage // empty')
rl_5h_rst=$(echo "$input"     | jq -r '.rate_limits.five_hour.resets_at // empty')
rl_7d_rst=$(echo "$input"     | jq -r '.rate_limits.seven_day.resets_at // empty')

# ---------------------------------------------------------------------------
# Directory — truncated to 3 path components (mirrors Starship truncation_length=3)
# Replace $HOME with ~
# ---------------------------------------------------------------------------
display_path="${cwd/#$HOME/~}"
# Keep only last 3 components
truncated=$(echo "$display_path" | awk -F/ '{
    n = NF
    if (n <= 3) { print $0 }
    else { printf "…/%s/%s/%s", $(n-2), $(n-1), $n }
}')

# ---------------------------------------------------------------------------
# Username
# ---------------------------------------------------------------------------
user_name=$(whoami)

# ---------------------------------------------------------------------------
# Git branch + dirty status (skips optional locks)
# ---------------------------------------------------------------------------
git_info=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
    if [ -n "$branch" ]; then
        dirty=$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)
        if [ -n "$dirty" ]; then
            git_info=" ${C_AQUA} ${branch} ✗${C_RESET}"
        else
            git_info=" ${C_AQUA} ${branch}${C_RESET}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Context usage with colour coding (green < 50%, yellow < 80%, red >= 80%)
# ---------------------------------------------------------------------------
context_info=""
total_input=$((input_tokens + cache_creation + cache_read))
if [ "$total_input" -gt 0 ] && [ -n "$context_window_size" ] && [ "$context_window_size" -gt 0 ]; then
    input_k=$(printf "%.0f" "$(echo "$total_input / 1000" | bc -l)")
    window_k=$(printf "%.0f" "$(echo "$context_window_size / 1000" | bc -l)")
    percentage=$(( (total_input * 100 + context_window_size / 2) / context_window_size ))
    if   [ "$percentage" -lt 50 ]; then ctx_color="$C_GREEN"
    elif [ "$percentage" -lt 80 ]; then ctx_color="$C_YELLOW"
    else                                 ctx_color="$C_RED"; fi
    context_info=" ${ctx_color}ctx:${input_k}k/${window_k}k (${percentage}%)${C_RESET}"
fi

# ---------------------------------------------------------------------------
# Rate limits
# ---------------------------------------------------------------------------
rl_info=""
if [ -n "$rl_5h_pct" ]; then
    rl_5h_int=$(printf "%.0f" "$rl_5h_pct")
    rl_7d_int=$(printf "%.0f" "${rl_7d_pct:-0}")
    if   [ "$rl_5h_int" -lt 50 ]; then rl_color="$C_GREEN"
    elif [ "$rl_5h_int" -lt 80 ]; then rl_color="$C_YELLOW"
    else                                rl_color="$C_RED"; fi
    rl_info=" ${rl_color}rl:${rl_5h_int}%/5h ${rl_7d_int}%/7d${C_RESET}"

    # Signal the smart-resume watcher at 90% (display turns red at 80%, but the
    # watcher only needs to start polling when a hit is imminent). Writing a data
    # file instead of a zero-byte sentinel lets the wrapper read the pre-computed
    # reset epochs directly — no JSONL parsing needed after Claude exits.
    rl_warn_flag="${HOME}/.claude/.rl_warn"
    if [ "$rl_5h_int" -ge 90 ] || [ "$rl_7d_int" -ge 90 ]; then
        printf '5h_pct=%s\n5h_reset=%s\n7d_pct=%s\n7d_reset=%s\n' \
            "$rl_5h_int" "${rl_5h_rst:-0}" \
            "$rl_7d_int" "${rl_7d_rst:-0}" > "$rl_warn_flag"
    else
        rm -f "$rl_warn_flag"
    fi
fi

# ---------------------------------------------------------------------------
# Model — short name only (strip "Claude " prefix to save space)
# Append Claude Code version when available, e.g. [Sonnet 4.6 v1.2.3]
# ---------------------------------------------------------------------------
model_info=""
if [ -n "$model_name" ]; then
    short_model="${model_name#Claude }"
    if [ -n "$version" ]; then
        model_info=" ${C_FG2}[${short_model} v${version}]${C_RESET}"
    else
        model_info=" ${C_FG2}[${short_model}]${C_RESET}"
    fi
fi

# ---------------------------------------------------------------------------
# Output style
# ---------------------------------------------------------------------------
style_info=""
[ -n "$output_style" ] && style_info=" ${C_FG2}{${output_style}}${C_RESET}"

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------
cost_info=""
if [ -n "$session_cost" ]; then
    cost_fmt=$(printf "%.2f" "$session_cost")
    cost_info=" ${C_FG2}\$${cost_fmt}${C_RESET}"
fi

# ---------------------------------------------------------------------------
# Assemble status line
# user @ dir  branch  [model] {style}  ctx  rl  cost
# ---------------------------------------------------------------------------
printf "${C_ORANGE}%s${C_RESET}" "$user_name"
printf "${C_FG0} @ ${C_RESET}"
printf "${C_YELLOW}%s${C_RESET}" "$truncated"
[ -n "$git_info"     ] && printf "%s" "$git_info"
[ -n "$model_info"   ] && printf "%s" "$model_info"
[ -n "$style_info"   ] && printf "%s" "$style_info"
[ -n "$context_info" ] && printf "%s" "$context_info"
[ -n "$rl_info"      ] && printf "%s" "$rl_info"
[ -n "$cost_info"    ] && printf "%s" "$cost_info"
