#!/usr/bin/env bash
# install-linux.sh: Install, inspect, or uninstall Antigravity Proxy Fix on Ubuntu/Linux.
#
# Usage:
#   ./linux/install-linux.sh [--proxy http://127.0.0.1:7897] [--app-bin /path/to/Antigravity] [--with-debug-port | --no-debug-port]
#   ./linux/install-linux.sh --status
#   ./linux/install-linux.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agy-proxy"
CONF_FILE="$CONF_DIR/proxy.conf"
APP_BIN_FILE="$CONF_DIR/app-bin.conf"

SHIM_BIN_DIR="$DATA_HOME/agy-proxy/bin"
USER_BIN_DIR="$HOME/.local/bin"
USER_APPS_DIR="$DATA_HOME/applications"
USER_DESKTOP="$USER_APPS_DIR/antigravity.desktop"
DESKTOP_BACKUP="$CONF_DIR/antigravity.desktop.pre-proxy.bak"

AGY_WRAPPER_DEST="$SHIM_BIN_DIR/agy"
GUI_WRAPPER_DEST="$USER_BIN_DIR/antigravity-proxy"
LEGACY_AGY_WRAPPER="$USER_BIN_DIR/agy"

MODE="install"
PROXY_URL=""
APP_BIN_ARG=""
DEBUG_PORT_MODE="auto" # auto | yes | no

usage() {
    cat <<'EOF'
Usage: install-linux.sh [OPTIONS]

Options:
  --proxy URL_OR_PORT   Write default proxy to ~/.config/agy-proxy/proxy.conf
                        (e.g. http://127.0.0.1:7890 or 7897).
  --app-bin PATH        Path to the Antigravity executable (e.g. ./Antigravity
                        from Antigravity.tar.gz) or its extracted folder. Saved to
                        ~/.config/agy-proxy/app-bin.conf and used to create/update
                        ~/.local/share/applications/antigravity.desktop.
  --with-debug-port     Add --remote-debugging-port=0 --remote-debugging-address=127.0.0.1
                        to ~/.local/share/applications/antigravity.desktop (needed for
                        Antigrative Dashboard / antigravity-pulse inline bar).
  --no-debug-port       Do not auto-add loopback debug flags even if antigravity-pulse
                        is detected.
  --status              Show current Linux installation and proxy status.
  --uninstall           Remove installed wrappers, generated/managed desktop entry,
                        and app-bin.conf (keeps proxy.conf and official ~/.local/bin/agy).
  -h, --help            Show this help message.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --proxy)
            if [ $# -lt 2 ]; then
                printf '[ERROR] --proxy requires an argument\n' >&2
                exit 1
            fi
            PROXY_URL="$2"
            shift 2
            ;;
        --proxy=*)
            PROXY_URL="${1#--proxy=}"
            shift
            ;;
        --app-bin)
            if [ $# -lt 2 ]; then
                printf '[ERROR] --app-bin requires a file or directory path\n' >&2
                exit 1
            fi
            APP_BIN_ARG="$2"
            shift 2
            ;;
        --app-bin=*)
            APP_BIN_ARG="${1#--app-bin=}"
            shift
            ;;
        --with-debug-port)
            DEBUG_PORT_MODE="yes"
            shift
            ;;
        --no-debug-port)
            DEBUG_PORT_MODE="no"
            shift
            ;;
        --status)
            MODE="status"
            shift
            ;;
        --uninstall)
            MODE="uninstall"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf '[ERROR] Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

resolve_abs_path() {
    if command -v readlink >/dev/null 2>&1; then
        readlink -f -- "$1" 2>/dev/null || printf '%s\n' "$1"
    elif command -v realpath >/dev/null 2>&1; then
        realpath -- "$1" 2>/dev/null || printf '%s\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

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

is_our_wrapper() {
    local f="$1"
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
    local first_line head30
    first_line="$(head -n 1 -- "$f" 2>/dev/null | tr -d '\0' || true)"
    case "$first_line" in
        *bash*) ;;
        *) return 1 ;;
    esac
    head30="$(head -n 30 -- "$f" 2>/dev/null | tr -d '\0' || true)"
    case "$head30" in
        *agy-shim-linux*) return 0 ;;
        *) return 1 ;;
    esac
}

is_valid_app_exe() {
    local f="$1"
    [ -f "$f" ] && [ -x "$f" ] || return 1
    local r gui_r shim_r
    r="$(resolve_abs_path "$f")"
    gui_r="$(resolve_abs_path "$GUI_WRAPPER_DEST")"
    shim_r="$(resolve_abs_path "$AGY_WRAPPER_DEST")"
    [ "$r" != "$gui_r" ] && [ "$r" != "$shim_r" ]
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

    local p sub cand
    p="$(expand_tilde "$raw")"
    if [ -d "$p" ]; then
        for sub in "Antigravity" "antigravity" "antigravity-ide"; do
            cand="${p%/}/$sub"
            if is_valid_app_exe "$cand"; then
                resolve_abs_path "$cand"
                return 0
            fi
        done
        return 1
    fi

    if is_valid_app_exe "$p"; then
        resolve_abs_path "$p"
        return 0
    fi
    return 1
}

read_app_bin_conf() {
    [ -f "$APP_BIN_FILE" ] || return 1
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
    done < "$APP_BIN_FILE"
    return 1
}

extract_desktop_exec_bin() {
    local desktop_file="$1"
    [ -f "$desktop_file" ] || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    local cmd_tok
    cmd_tok="$(python3 - "$desktop_file" <<'PYEOF'
import os, re, shlex, sys

with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as fh:
    for line in fh:
        m = re.match(r"^\s*Exec\s*=\s*(.+)$", line)
        if not m:
            continue
        rhs = m.group(1).strip()
        try:
            tokens = shlex.split(rhs)
        except ValueError:
            tokens = rhs.split()
        if not tokens:
            break
        idx = 0
        if os.path.basename(tokens[0]) == "env":
            idx = 1
            while idx < len(tokens) and ("=" in tokens[idx] or tokens[idx].startswith("-")):
                idx += 1
        if idx < len(tokens):
            print(tokens[idx])
        break
PYEOF
)"
    [ -n "$cmd_tok" ] || return 1
    if [[ "$cmd_tok" != */* ]]; then
        cmd_tok="$(command -v "$cmd_tok" 2>/dev/null || true)"
    fi
    [ -n "$cmd_tok" ] || return 1
    resolve_app_candidate "$cmd_tok"
}

detect_desktop_binary() {
    read_app_bin_conf && return 0

    if [ -n "${ANTIGRAVITY_REAL_BIN:-}" ]; then
        resolve_app_candidate "$ANTIGRAVITY_REAL_BIN" && return 0
    fi

    local d
    for d in \
        "$USER_DESKTOP" \
        "/usr/share/applications/antigravity.desktop" \
        "/usr/local/share/applications/antigravity.desktop"; do
        if [ -f "$d" ] && ! grep -q 'antigravity-proxy' "$d" 2>/dev/null; then
            extract_desktop_exec_bin "$d" && return 0
        fi
    done

    local cand
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
        "/usr/local/bin/antigravity" \
        "$PWD/Antigravity" \
        "$PWD/antigravity"; do
        if is_valid_app_exe "$cand"; then
            resolve_abs_path "$cand"
            return 0
        fi
    done

    return 1
}

show_status() {
    local detected_app=""
    detected_app="$(detect_desktop_binary || true)"

    printf '\n=== Wrappers ===\n'
    if [ -x "$AGY_WRAPPER_DEST" ]; then
        printf '  CLI shim    : %s [installed] (%s)\n' "$AGY_WRAPPER_DEST" "$("$AGY_WRAPPER_DEST" --shim-version 2>/dev/null || printf 'unknown')"
    else
        printf '  CLI shim    : %s [not installed]\n' "$AGY_WRAPPER_DEST"
    fi
    if is_our_wrapper "$LEGACY_AGY_WRAPPER"; then
        printf '  Legacy shim : %s [present; re-run install-linux.sh to migrate]\n' "$LEGACY_AGY_WRAPPER"
    elif [ -e "$LEGACY_AGY_WRAPPER" ]; then
        printf '  Official CLI: %s [present, untouched]\n' "$LEGACY_AGY_WRAPPER"
    fi
    if [ -x "$GUI_WRAPPER_DEST" ]; then
        printf '  GUI wrapper : %s [installed] (%s)\n' "$GUI_WRAPPER_DEST" "$("$GUI_WRAPPER_DEST" --proxy-launcher-version 2>/dev/null || printf 'unknown')"
    else
        printf '  GUI wrapper : %s [not installed]\n' "$GUI_WRAPPER_DEST"
    fi

    local resolved_agy resolved_gui
    resolved_agy="$(command -v agy 2>/dev/null || true)"
    resolved_gui="$(command -v antigravity-proxy 2>/dev/null || true)"
    printf '  which agy   : %s\n' "${resolved_agy:-<not on PATH>}"
    if [ -x "$AGY_WRAPPER_DEST" ] && [ "$resolved_agy" != "$AGY_WRAPPER_DEST" ]; then
        printf '    [WARN] %s is not first on PATH (official or missing binary resolved instead).\n' "$SHIM_BIN_DIR"
    fi
    printf '  which gui   : %s\n' "${resolved_gui:-<not on PATH>}"

    printf '\n=== App binary & proxy config ===\n'
    if [ -f "$APP_BIN_FILE" ]; then
        printf '  app-bin.conf: %s -> %s\n' "$APP_BIN_FILE" "${detected_app:-<invalid or missing>}"
    elif [ -n "$detected_app" ]; then
        printf '  app binary  : %s [auto-detected; app-bin.conf not set]\n' "$detected_app"
    else
        printf '  app binary  : [not detected; pass --app-bin /path/to/Antigravity or set ANTIGRAVITY_REAL_BIN]\n'
    fi

    if [ -f "$CONF_FILE" ]; then
        printf '  proxy.conf  : %s:\n' "$CONF_FILE"
        sed 's/^/    /' "$CONF_FILE"
    else
        printf '  proxy.conf  : %s [not set; auto-probes 7897 -> 7890 -> 10809]\n' "$CONF_FILE"
    fi

    printf '\n=== Desktop entry ===\n'
    if [ -f "$USER_DESKTOP" ]; then
        printf '  %s [present]\n' "$USER_DESKTOP"
        grep -E '^\s*(Exec|Path|X-Antigravity-Proxy-Generated|X-Antigravity-Pulse-Managed)=' "$USER_DESKTOP" | sed 's/^/    /' || true
    else
        printf '  %s [not present]\n' "$USER_DESKTOP"
    fi

    printf '\n=== Global proxy vars (should normally be unset) ===\n'
    local v val
    for v in HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy; do
        val="${!v-}"
        printf '  %-14s = %s\n' "$v" "${val:-<unset>}"
    done

    printf '\n=== Local proxy port probe ===\n'
    local p
    for p in 7897 7890 10809; do
        if timeout 0.4 bash -c 'exec 3<>"/dev/tcp/127.0.0.1/$1"' _ "$p" 2>/dev/null; then
            printf '  127.0.0.1:%-5s open\n' "$p"
        else
            printf '  127.0.0.1:%-5s closed\n' "$p"
        fi
    done
}

do_uninstall() {
    local removed=0
    if [ -f "$AGY_WRAPPER_DEST" ]; then
        rm -f -- "$AGY_WRAPPER_DEST"
        printf 'Removed: %s\n' "$AGY_WRAPPER_DEST"
        rmdir "$SHIM_BIN_DIR" 2>/dev/null || true
        rmdir "$DATA_HOME/agy-proxy" 2>/dev/null || true
        removed=1
    fi
    if is_our_wrapper "$LEGACY_AGY_WRAPPER"; then
        rm -f -- "$LEGACY_AGY_WRAPPER"
        printf 'Removed legacy CLI wrapper: %s\n' "$LEGACY_AGY_WRAPPER"
        removed=1
    fi
    if [ -f "$GUI_WRAPPER_DEST" ]; then
        rm -f -- "$GUI_WRAPPER_DEST"
        printf 'Removed: %s\n' "$GUI_WRAPPER_DEST"
        removed=1
    fi

    if [ -f "$DESKTOP_BACKUP" ]; then
        mkdir -p -- "$USER_APPS_DIR"
        mv -f -- "$DESKTOP_BACKUP" "$USER_DESKTOP"
        printf 'Restored previous desktop entry: %s\n' "$USER_DESKTOP"
        removed=1
    elif [ -f "$USER_DESKTOP" ] && grep -qE 'antigravity-proxy|X-Antigravity-Proxy-Generated=true' "$USER_DESKTOP"; then
        rm -f -- "$USER_DESKTOP"
        printf 'Removed managed desktop entry: %s\n' "$USER_DESKTOP"
        removed=1
    fi

    if [ -f "$APP_BIN_FILE" ]; then
        rm -f -- "$APP_BIN_FILE"
        printf 'Removed: %s\n' "$APP_BIN_FILE"
        removed=1
    fi

    if command -v update-desktop-database >/dev/null 2>&1 && [ -d "$USER_APPS_DIR" ]; then
        update-desktop-database "$USER_APPS_DIR" 2>/dev/null || true
    fi

    if [ "$removed" -eq 0 ]; then
        printf 'Nothing to uninstall.\n'
    else
        printf 'Uninstall complete. proxy.conf (if any) kept at %s\n' "$CONF_FILE"
    fi
}

patch_desktop_file() {
    local src_desktop="$1"
    local dst_desktop="$2"
    local wrapper_path="$3"
    local add_debug="$4"

    if ! command -v python3 >/dev/null 2>&1; then
        printf '[WARN] python3 not found; skipping automatic .desktop rewrite.\n' >&2
        printf '       Manually copy %s to %s and replace the Exec= binary with %s\n' \
            "$src_desktop" "$dst_desktop" "$wrapper_path" >&2
        return 1
    fi

    python3 - "$src_desktop" "$dst_desktop" "$wrapper_path" "$add_debug" <<'PYEOF'
import os
import re
import shlex
import sys

src, dst, wrapper, add_debug_flag = sys.argv[1:5]
add_debug = add_debug_flag == "yes"
DEBUG_PORT = "--remote-debugging-port=0"
DEBUG_ADDR = "--remote-debugging-address=127.0.0.1"
FIELD_CODE_RE = re.compile(r"^%[fFuUdDnNickvm]$")


def quote_exec_arg(arg: str) -> str:
    if not arg or any(ch in arg for ch in ' \t"\'\\$`<>|&;()*?#~'):
        escaped = arg.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
        return f'"{escaped}"'
    return arg


def rewrite_exec_rhs(rhs: str) -> str:
    try:
        tokens = shlex.split(rhs)
    except ValueError:
        tokens = rhs.split()
    if not tokens:
        return rhs

    # Strip leading `env KEY=VAL ...` if present to find the actual binary token.
    idx = 0
    if os.path.basename(tokens[0]) == "env":
        idx = 1
        while idx < len(tokens) and ("=" in tokens[idx] or tokens[idx].startswith("-")):
            idx += 1
        if idx >= len(tokens):
            idx = 0

    rest = tokens[idx + 1 :] if idx < len(tokens) else []
    new_tokens = [wrapper] + rest

    if add_debug:
        has_port = any(t == "--remote-debugging-port" or t.startswith("--remote-debugging-port=") for t in new_tokens[1:])
        has_addr = any(t == "--remote-debugging-address" or t.startswith("--remote-debugging-address=") for t in new_tokens[1:])
        extra = []
        if not has_port:
            extra.append(DEBUG_PORT)
        if not has_addr:
            extra.append(DEBUG_ADDR)
        if extra:
            insert_at = len(new_tokens)
            for i in range(1, len(new_tokens)):
                if FIELD_CODE_RE.match(new_tokens[i]) or new_tokens[i] == "--":
                    insert_at = i
                    break
            new_tokens = new_tokens[:insert_at] + extra + new_tokens[insert_at:]

    return " ".join(quote_exec_arg(t) for t in new_tokens)


with open(src, "r", encoding="utf-8") as fh:
    lines = fh.read().splitlines()

out = []
for line in lines:
    m = re.match(r"^(\s*Exec\s*=\s*)(.+)$", line)
    if m:
        out.append(m.group(1) + rewrite_exec_rhs(m.group(2).strip()))
    else:
        out.append(line)

os.makedirs(os.path.dirname(dst), exist_ok=True)
tmp = f"{dst}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(out) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, dst)
PYEOF
}

generate_desktop_file() {
    local dst_desktop="$1"
    local wrapper_path="$2"
    local app_bin="$3"
    local add_debug="$4"

    if ! command -v python3 >/dev/null 2>&1; then
        printf '[WARN] python3 not found; skipping automatic .desktop generation.\n' >&2
        return 1
    fi

    python3 - "$dst_desktop" "$wrapper_path" "$app_bin" "$add_debug" <<'PYEOF'
import os
import re
import shlex
import sys

dst, wrapper, app_bin, add_debug_flag = sys.argv[1:5]
add_debug = add_debug_flag == "yes"
DEBUG_PORT = "--remote-debugging-port=0"
DEBUG_ADDR = "--remote-debugging-address=127.0.0.1"
FIELD_CODE_RE = re.compile(r"^%[fFuUdDnNickvm]$")


def quote_exec_arg(arg: str) -> str:
    if not arg or any(ch in arg for ch in ' \t"\'\\$`<>|&;()*?#~'):
        escaped = arg.replace("\\", "\\\\").replace('"', '\\"').replace("$", "\\$").replace("`", "\\`")
        return f'"{escaped}"'
    return arg


app_dir = os.path.dirname(os.path.realpath(app_bin))

icon_value = "antigravity"
for rel in (
    "resources/app/resources/linux/code.png",
    "resources/app/resources/linux/antigravity.png",
    "resources/app/out/media/code-icon.svg",
    "antigravity.png",
    "Antigravity.png",
    "icon.png",
    "antigravity.svg",
):
    cand = os.path.join(app_dir, rel)
    if os.path.isfile(cand):
        icon_value = cand
        break

extra_tokens = []
field_codes = []
if os.path.isfile(dst):
    with open(dst, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = re.match(r"^\s*Exec\s*=\s*(.+)$", line)
            if m:
                try:
                    toks = shlex.split(m.group(1).strip())
                except ValueError:
                    toks = m.group(1).strip().split()
                for t in toks[1:]:
                    if FIELD_CODE_RE.match(t):
                        field_codes.append(t)
                    else:
                        extra_tokens.append(t)
                break

if not field_codes:
    field_codes = ["%F"]

new_tokens = [wrapper] + extra_tokens + field_codes

if add_debug:
    has_port = any(t == "--remote-debugging-port" or t.startswith("--remote-debugging-port=") for t in new_tokens[1:])
    has_addr = any(t == "--remote-debugging-address" or t.startswith("--remote-debugging-address=") for t in new_tokens[1:])
    debug_extra = []
    if not has_port:
        debug_extra.append(DEBUG_PORT)
    if not has_addr:
        debug_extra.append(DEBUG_ADDR)
    if debug_extra:
        insert_at = len(new_tokens)
        for i in range(1, len(new_tokens)):
            if FIELD_CODE_RE.match(new_tokens[i]) or new_tokens[i] == "--":
                insert_at = i
                break
        new_tokens = new_tokens[:insert_at] + debug_extra + new_tokens[insert_at:]

exec_line = " ".join(quote_exec_arg(t) for t in new_tokens)

lines = [
    "[Desktop Entry]",
    "Name=Antigravity",
    "Comment=Google Antigravity (via proxy)",
    "GenericName=AI Agent & Editor",
    f"Exec={exec_line}",
    f"Path={app_dir}",
    f"Icon={icon_value}",
    "Terminal=false",
    "Type=Application",
    "Categories=Development;IDE;",
    "StartupNotify=true",
    "StartupWMClass=Antigravity",
    "X-Antigravity-Proxy-Generated=true",
]

os.makedirs(os.path.dirname(dst), exist_ok=True)
tmp = f"{dst}.{os.getpid()}.tmp"
with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(tmp, 0o644)
os.replace(tmp, dst)
PYEOF
}

do_install() {
    local resolved_app_bin=""
    if [ -n "$APP_BIN_ARG" ]; then
        if ! resolved_app_bin="$(resolve_app_candidate "$APP_BIN_ARG")"; then
            printf '[ERROR] --app-bin target not found or not executable: %s\n' "$APP_BIN_ARG" >&2
            exit 1
        fi
    fi

    mkdir -p -- "$SHIM_BIN_DIR" "$USER_BIN_DIR"

    # Migrate away from legacy v2.1.0 ~/.local/bin/agy wrapper without touching official binary.
    if is_our_wrapper "$LEGACY_AGY_WRAPPER"; then
        rm -f -- "$LEGACY_AGY_WRAPPER"
        printf '[info] Migrated legacy wrapper out of %s (now installed to %s)\n' "$LEGACY_AGY_WRAPPER" "$AGY_WRAPPER_DEST"
    fi

    install -m 0755 "$SCRIPT_DIR/proxy-wrapper.sh" "$AGY_WRAPPER_DEST"
    install -m 0755 "$SCRIPT_DIR/proxy-wrapper.sh" "$GUI_WRAPPER_DEST"
    printf 'Installed CLI shim    : %s\n' "$AGY_WRAPPER_DEST"
    printf 'Installed GUI wrapper : %s\n' "$GUI_WRAPPER_DEST"

    if [ -n "$PROXY_URL" ]; then
        mkdir -p -- "$CONF_DIR"
        printf '# Proxy address for agy and antigravity-proxy (URL or port)\n%s\n' "$PROXY_URL" > "$CONF_FILE"
        printf 'Wrote proxy config    : %s -> %s\n' "$CONF_FILE" "$PROXY_URL"
    fi

    if [ -z "$resolved_app_bin" ]; then
        resolved_app_bin="$(detect_desktop_binary || true)"
    fi
    if [ -n "$resolved_app_bin" ]; then
        mkdir -p -- "$CONF_DIR"
        printf '# Real Antigravity executable path (for tarball or custom installs)\n%s\n' "$resolved_app_bin" > "$APP_BIN_FILE"
        printf 'Recorded app binary   : %s -> %s\n' "$APP_BIN_FILE" "$resolved_app_bin"
    fi

    # Decide whether to ensure loopback debug flags for Antigrative Dashboard.
    local want_debug="no"
    if [ "$DEBUG_PORT_MODE" = "yes" ]; then
        want_debug="yes"
    elif [ "$DEBUG_PORT_MODE" = "auto" ] && [ -d "$HOME/.gemini/config/plugins/antigravity-pulse" ]; then
        want_debug="yes"
        printf '[info] Detected antigravity-pulse plugin; ensuring loopback debug flags on desktop entry.\n'
    fi

    # Handle XDG desktop entry: preserve/patch existing non-generated .desktop, or generate one for tarball installs.
    local is_generated=0
    if [ -f "$USER_DESKTOP" ] && grep -q 'X-Antigravity-Proxy-Generated=true' "$USER_DESKTOP" 2>/dev/null; then
        is_generated=1
    fi

    local src_desktop=""
    if [ -f "$USER_DESKTOP" ] && [ "$is_generated" -eq 0 ]; then
        src_desktop="$USER_DESKTOP"
        if ! grep -q 'antigravity-proxy' "$USER_DESKTOP" && [ ! -f "$DESKTOP_BACKUP" ]; then
            mkdir -p -- "$CONF_DIR"
            cp -p -- "$USER_DESKTOP" "$DESKTOP_BACKUP"
        fi
    elif [ "$is_generated" -eq 0 ]; then
        local cand
        for cand in \
            "/usr/share/applications/antigravity.desktop" \
            "/usr/local/share/applications/antigravity.desktop"; do
            if [ -f "$cand" ]; then
                src_desktop="$cand"
                break
            fi
        done
    fi

    if [ -n "$src_desktop" ]; then
        patch_desktop_file "$src_desktop" "$USER_DESKTOP" "$GUI_WRAPPER_DEST" "$want_debug"
        printf 'Updated desktop entry : %s\n' "$USER_DESKTOP"
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$USER_APPS_DIR" 2>/dev/null || true
        fi
    elif [ -n "$resolved_app_bin" ]; then
        generate_desktop_file "$USER_DESKTOP" "$GUI_WRAPPER_DEST" "$resolved_app_bin" "$want_debug"
        printf 'Created desktop entry : %s\n' "$USER_DESKTOP"
        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database "$USER_APPS_DIR" 2>/dev/null || true
        fi
    else
        printf '[WARN] No system .desktop or Antigravity executable found; skipping .desktop creation.\n'
        printf '       Re-run with: ./linux/install-linux.sh --app-bin /path/to/Antigravity\n'
        printf '       Or run "%s" from inside your extracted Antigravity folder.\n' "$GUI_WRAPPER_DEST"
    fi

    # Check PATH ordering for CLI shim (must come BEFORE ~/.local/bin).
    printf '\n'
    local resolved_agy resolved_gui
    resolved_agy="$(command -v agy 2>/dev/null || true)"
    if [ "$resolved_agy" = "$AGY_WRAPPER_DEST" ]; then
        printf '[OK] PATH resolves agy -> %s\n' "$resolved_agy"
    else
        printf '[WARN] agy currently resolves to: %s\n' "${resolved_agy:-<none>}"
        printf '       Add ~/.local/share/agy-proxy/bin BEFORE ~/.local/bin in ~/.bashrc or ~/.zshrc:\n'
        printf '         export PATH="$HOME/.local/share/agy-proxy/bin:$PATH"\n'
    fi

    resolved_gui="$(command -v antigravity-proxy 2>/dev/null || true)"
    if [ "$resolved_gui" != "$GUI_WRAPPER_DEST" ]; then
        printf '[NOTE] %s is not active in PATH for antigravity-proxy (desktop icon works directly).\n' "$USER_BIN_DIR"
        printf '       To launch from terminal, also ensure PATH includes:\n'
        printf '         export PATH="$HOME/.local/bin:$PATH"\n'
    fi
}

case "$MODE" in
    install)   do_install ;;
    status)    show_status ;;
    uninstall) do_uninstall ;;
esac
