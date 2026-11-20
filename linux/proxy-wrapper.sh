#!/usr/bin/env bash
# proxy-wrapper.sh: Unified multi-call per-app proxy wrapper on Linux.
#
# Installed by linux/install-linux.sh to both:
#   ~/.local/bin/agy               (CLI wrapper)
#   ~/.local/bin/antigravity-proxy (Desktop GUI wrapper)
#
# Dispatches behavior based on basename "$0":
#   - Respects existing HTTP_PROXY / HTTPS_PROXY (never overwrites user config).
#   - Probes AGY_PROXY / ANTIGRAVITY_PROXY -> ~/.config/agy-proxy/proxy.conf
#     -> 7897 -> 7890 -> 10809.
#   - Injects proxy + NO_PROXY into this process tree only, then exec's the real
#     binary with all arguments preserved verbatim (TTY/TUI, signals, exit code,
#     and --remote-debugging-port flags for UI plugins).

set -u

WRAPPER_VERSION="2.1.0"
INVOKED_NAME="$(basename -- "$0")"

if [ "$INVOKED_NAME" = "agy" ]; then
    if [ "${1:-}" = "--shim-version" ]; then
        printf 'agy-shim-linux %s\n' "$WRAPPER_VERSION"
        exit 0
    fi
    PRIMARY_ENV_VAR="AGY_PROXY"
else
    if [ "${1:-}" = "--proxy-launcher-version" ]; then
        printf 'antigravity-proxy-linux %s\n' "$WRAPPER_VERSION"
        exit 0
    fi
    PRIMARY_ENV_VAR="ANTIGRAVITY_PROXY"
fi

resolve_path() {
    if command -v readlink >/dev/null 2>&1; then
        readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
    elif command -v realpath >/dev/null 2>&1; then
        realpath -- "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

SELF_REAL="$(resolve_path "$0")"

scan_path_for() {
    local name="$1"
    local IFS=':'
    local dir cand cand_real
    for dir in ${PATH:-}; do
        [ -z "$dir" ] && dir="."
        cand="${dir%/}/$name"
        if [ -f "$cand" ] && [ -x "$cand" ]; then
            cand_real="$(resolve_path "$cand")"
            if [ "$cand_real" != "$SELF_REAL" ]; then
                printf '%s\n' "$cand"
                return 0
            fi
        fi
    done
    return 1
}

find_real_binary() {
    local cand cand_real

    if [ "$INVOKED_NAME" = "agy" ]; then
        if [ -n "${AGY_REAL_BIN:-}" ] && [ -x "$AGY_REAL_BIN" ]; then
            printf '%s\n' "$AGY_REAL_BIN"
            return 0
        fi
        scan_path_for "agy" && return 0
        for cand in \
            "$HOME/.local/share/agy/bin/agy" \
            "$HOME/.agy/bin/agy" \
            "/usr/local/bin/agy" \
            "/usr/bin/agy"; do
            if [ -f "$cand" ] && [ -x "$cand" ]; then
                cand_real="$(resolve_path "$cand")"
                if [ "$cand_real" != "$SELF_REAL" ]; then
                    printf '%s\n' "$cand"
                    return 0
                fi
            fi
        done
        return 1
    fi

    if [ -n "${ANTIGRAVITY_REAL_BIN:-}" ] && [ -x "$ANTIGRAVITY_REAL_BIN" ]; then
        printf '%s\n' "$ANTIGRAVITY_REAL_BIN"
        return 0
    fi

    for cand in \
        "/opt/Antigravity/antigravity" \
        "/opt/antigravity/antigravity" \
        "/usr/share/antigravity/antigravity" \
        "/usr/bin/antigravity" \
        "/usr/local/bin/antigravity"; do
        if [ -f "$cand" ] && [ -x "$cand" ]; then
            cand_real="$(resolve_path "$cand")"
            if [ "$cand_real" != "$SELF_REAL" ]; then
                printf '%s\n' "$cand"
                return 0
            fi
        fi
    done

    scan_path_for "antigravity" && return 0
    return 1
}

normalize_proxy() {
    local raw="${1:-}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw#\"}"
    raw="${raw%\"}"
    raw="${raw#\'}"
    raw="${raw%\'}"
    [ -z "$raw" ] && return 1

    if [[ "$raw" =~ ^[0-9]+$ ]] && [ "$raw" -ge 1 ] && [ "$raw" -le 65535 ]; then
        printf 'http://127.0.0.1:%s\n' "$raw"
        return 0
    fi

    if [[ "$raw" != *"://"* ]]; then
        raw="http://$raw"
    fi

    printf '%s\n' "$raw"
}

read_proxy_conf() {
    local conf="${XDG_CONFIG_HOME:-$HOME/.config}/agy-proxy/proxy.conf"
    [ -f "$conf" ] || return 1

    local line key val
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        case "$line" in
            \#*|\;*) continue ;;
        esac
        if [[ "$line" == *=* ]]; then
            key="${line%%=*}"
            val="${line#*=}"
            key="${key#"${key%%[![:space:]]*}"}"
            key="${key%"${key##*[![:space:]]}"}"
            case "${key^^}" in
                AGY_PROXY|ANTIGRAVITY_PROXY|HTTPS_PROXY|HTTP_PROXY|PROXY)
                    line="$val"
                    ;;
            esac
        fi
        normalize_proxy "$line" && return 0
    done < "$conf"

    return 1
}

probe_proxy_url() {
    local url="$1"
    local no_scheme="${url#*://}"
    local authority="${no_scheme%%/*}"
    authority="${authority##*@}"
    local host port
    if [[ "$authority" == \[*\]* ]]; then
        host="${authority#\[}"
        host="${host%%\]*}"
        port="${authority##*\]:}"
    else
        host="${authority%:*}"
        port="${authority##*:}"
    fi

    if [ -z "$host" ] || ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi

    if command -v timeout >/dev/null 2>&1; then
        if timeout 0.4 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" 2>/dev/null; then
            return 0
        fi
    elif command -v python3 >/dev/null 2>&1; then
        if python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1],int(sys.argv[2])),0.4); s.close()' "$host" "$port" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

maybe_set_proxy() {
    local primary_var="$1"

    if [ -n "${HTTPS_PROXY:-}" ] || [ -n "${https_proxy:-}" ] || \
       [ -n "${HTTP_PROXY:-}" ] || [ -n "${http_proxy:-}" ]; then
        return 0
    fi

    local -a candidates=()
    local primary_val="${!primary_var-}"
    local c norm

    if [ -n "$primary_val" ]; then
        norm="$(normalize_proxy "$primary_val" || true)"
        [ -n "$norm" ] && candidates+=("$norm")
    fi

    norm="$(read_proxy_conf || true)"
    [ -n "$norm" ] && candidates+=("$norm")

    candidates+=(
        "http://127.0.0.1:7897"
        "http://127.0.0.1:7890"
        "http://127.0.0.1:10809"
    )

    local chosen=""
    local seen="|"
    for c in "${candidates[@]}"; do
        case "$seen" in
            *"|$c|"*) continue ;;
        esac
        seen="${seen}${c}|"
        if probe_proxy_url "$c"; then
            chosen="$c"
            break
        fi
    done

    [ -z "$chosen" ] && return 0

    export HTTPS_PROXY="$chosen"
    export HTTP_PROXY="$chosen"
    export https_proxy="$chosen"
    export http_proxy="$chosen"

    if [ -z "${NO_PROXY:-}" ] && [ -z "${no_proxy:-}" ]; then
        export NO_PROXY="localhost,127.0.0.1,::1"
        export no_proxy="localhost,127.0.0.1,::1"
    fi
}

REAL_BIN="$(find_real_binary || true)"
if [ -z "$REAL_BIN" ]; then
    if [ "$INVOKED_NAME" = "agy" ]; then
        printf 'agy-shim-linux: cannot locate real agy binary (set AGY_REAL_BIN to override)\n' >&2
    else
        printf 'antigravity-proxy-linux: cannot locate real antigravity binary (set ANTIGRAVITY_REAL_BIN to override)\n' >&2
    fi
    exit 1
fi

maybe_set_proxy "$PRIMARY_ENV_VAR"
exec "$REAL_BIN" "$@"
