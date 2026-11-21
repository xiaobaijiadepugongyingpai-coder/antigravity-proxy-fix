#!/usr/bin/env bash
# proxy-wrapper.sh: Unified multi-call per-app proxy wrapper on Linux.
#
# Installed by linux/install-linux.sh to:
#   ~/.local/share/agy-proxy/bin/agy  (CLI wrapper; never overwrites ~/.local/bin/agy)
#   ~/.local/bin/antigravity-proxy    (Desktop GUI wrapper)
#
# Dispatches behavior based on basename "$0":
#   - Respects existing HTTP_PROXY / HTTPS_PROXY (never overwrites user config).
#   - Probes AGY_PROXY / ANTIGRAVITY_PROXY -> ~/.config/agy-proxy/proxy.conf
#     -> 7897 -> 7890 -> 10809.
#   - Injects proxy + NO_PROXY into this process tree only, then exec's the real
#     binary with all arguments preserved verbatim (TTY/TUI, signals, exit code,
#     and --remote-debugging-port flags for UI plugins).
#   - For Desktop GUI mode on Linux/GNOME, Chromium prioritizes gsettings over
#     HTTPS_PROXY, so --proxy-server and --proxy-bypass-list are also passed when
#     an active proxy is resolved (disable via ANTIGRAVITY_NO_ELECTRON_PROXY_FLAG=1).

set -u

WRAPPER_VERSION="2.2.0"
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
EFFECTIVE_PROXY=""

expand_tilde() {
    local p="$1"
    case "$p" in
        "~")
            printf '%s\n' "$HOME"
            ;;
        "~/"*)
            printf '%s/%s\n' "$HOME" "${p#"~/"}"
            ;;
        *)
            printf '%s\n' "$p"
            ;;
    esac
}

is_real_exe() {
    local cand="$1"
    local cand_real
    if [ -f "$cand" ] && [ -x "$cand" ]; then
        cand_real="$(resolve_path "$cand")"
        if [ "$cand_real" != "$SELF_REAL" ]; then
            return 0
        fi
    fi
    return 1
}

resolve_app_candidate() {
    local raw="${1:-}"
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    raw="${raw#\"}"
    raw="${raw%\"}"
    raw="${raw#\'}"
    raw="${raw%\'}"
    [ -z "$raw" ] && return 1

    local p sub
    p="$(expand_tilde "$raw")"
    if [ -d "$p" ]; then
        for sub in "Antigravity" "antigravity" "antigravity-ide"; do
            if is_real_exe "${p%/}/$sub"; then
                printf '%s\n' "${p%/}/$sub"
                return 0
            fi
        done
        return 1
    fi

    if is_real_exe "$p"; then
        printf '%s\n' "$p"
        return 0
    fi
    return 1
}

read_app_bin_conf() {
    local conf="${XDG_CONFIG_HOME:-$HOME/.config}/agy-proxy/app-bin.conf"
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
                APP_BIN|ANTIGRAVITY_REAL_BIN|ANTIGRAVITY_BIN)
                    line="$val"
                    ;;
            esac
        fi
        resolve_app_candidate "$line" && return 0
    done < "$conf"

    return 1
}

scan_path_for() {
    local name="$1"
    local IFS=':'
    local dir cand
    for dir in ${PATH:-}; do
        [ -z "$dir" ] && dir="."
        cand="${dir%/}/$name"
        if is_real_exe "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done
    return 1
}

find_real_binary() {
    local cand

    if [ "$INVOKED_NAME" = "agy" ]; then
        if [ -n "${AGY_REAL_BIN:-}" ] && is_real_exe "$AGY_REAL_BIN"; then
            printf '%s\n' "$AGY_REAL_BIN"
            return 0
        fi
        scan_path_for "agy" && return 0
        for cand in \
            "$HOME/.local/bin/agy" \
            "$HOME/.local/share/agy/bin/agy" \
            "$HOME/.agy/bin/agy" \
            "/usr/local/bin/agy" \
            "/usr/bin/agy"; do
            if is_real_exe "$cand"; then
                printf '%s\n' "$cand"
                return 0
            fi
        done
        return 1
    fi

    if [ -n "${ANTIGRAVITY_REAL_BIN:-}" ]; then
        resolve_app_candidate "$ANTIGRAVITY_REAL_BIN" && return 0
    fi

    read_app_bin_conf && return 0

    for cand in \
        "/opt/Antigravity/Antigravity" \
        "/opt/Antigravity/antigravity" \
        "/opt/antigravity/Antigravity" \
        "/opt/antigravity/antigravity" \
        "$HOME/Applications/Antigravity/Antigravity" \
        "$HOME/Applications/Antigravity/antigravity" \
        "$HOME/Antigravity/Antigravity" \
        "$HOME/Antigravity/antigravity" \
        "$HOME/Downloads/Antigravity/Antigravity" \
        "$HOME/Downloads/Antigravity/antigravity" \
        "$HOME/Downloads/Antigravity" \
        "$HOME/Antigravity" \
        "/usr/share/antigravity/antigravity" \
        "/usr/bin/antigravity" \
        "/usr/local/bin/antigravity"; do
        if is_real_exe "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

    scan_path_for "Antigravity" && return 0
    scan_path_for "antigravity" && return 0

    for cand in "$PWD/Antigravity" "$PWD/antigravity"; do
        if is_real_exe "$cand"; then
            printf '%s\n' "$cand"
            return 0
        fi
    done

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
        EFFECTIVE_PROXY="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
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
    EFFECTIVE_PROXY="$chosen"

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
        printf "antigravity-proxy-linux: cannot locate real Antigravity binary (run 'linux/install-linux.sh --app-bin /path/to/Antigravity' or set ANTIGRAVITY_REAL_BIN)\n" >&2
    fi
    exit 1
fi

maybe_set_proxy "$PRIMARY_ENV_VAR"

if [ "$INVOKED_NAME" = "agy" ]; then
    exec "$REAL_BIN" "$@"
fi

if [ -n "$EFFECTIVE_PROXY" ] && [ "${ANTIGRAVITY_NO_ELECTRON_PROXY_FLAG:-0}" != "1" ]; then
    skip_flag=0
    for arg in "$@"; do
        case "$arg" in
            --proxy-server|--proxy-server=*|--no-proxy-server|--help|-h|--version|-v)
                skip_flag=1
                break
                ;;
        esac
    done
    if [ "$skip_flag" -eq 0 ]; then
        exec "$REAL_BIN" \
            "--proxy-server=$EFFECTIVE_PROXY" \
            "--proxy-bypass-list=localhost;127.0.0.1;[::1]" \
            "$@"
    fi
fi

exec "$REAL_BIN" "$@"
