#!/usr/bin/env bash
# install-linux.sh: Install, inspect, or uninstall Antigravity Proxy Fix on Ubuntu/Linux.
#
# Usage:
#   ./linux/install-linux.sh [--proxy http://127.0.0.1:7897] [--with-debug-port | --no-debug-port]
#   ./linux/install-linux.sh --status
#   ./linux/install-linux.sh --uninstall

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/agy-proxy"
CONF_FILE="$CONF_DIR/proxy.conf"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
USER_APPS_DIR="$DATA_HOME/applications"
USER_DESKTOP="$USER_APPS_DIR/antigravity.desktop"
DESKTOP_BACKUP="$CONF_DIR/antigravity.desktop.pre-proxy.bak"

AGY_WRAPPER_DEST="$BIN_DIR/agy"
GUI_WRAPPER_DEST="$BIN_DIR/antigravity-proxy"

MODE="install"
PROXY_URL=""
DEBUG_PORT_MODE="auto" # auto | yes | no

usage() {
    cat <<'EOF'
Usage: install-linux.sh [OPTIONS]

Options:
  --proxy URL_OR_PORT   Write default proxy to ~/.config/agy-proxy/proxy.conf
                        (e.g. http://127.0.0.1:7890 or 7897).
  --with-debug-port     Add --remote-debugging-port=0 --remote-debugging-address=127.0.0.1
                        to ~/.local/share/applications/antigravity.desktop (needed for
                        Antigrative Dashboard / antigravity-pulse inline bar).
  --no-debug-port       Do not auto-add loopback debug flags even if antigravity-pulse
                        is detected.
  --status              Show current Linux installation and proxy status.
  --uninstall           Remove installed wrappers and user desktop override.
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

show_status() {
    printf '\n=== Wrappers ===\n'
    if [ -x "$AGY_WRAPPER_DEST" ]; then
        printf '  CLI wrapper : %s [installed] (%s)\n' "$AGY_WRAPPER_DEST" "$("$AGY_WRAPPER_DEST" --shim-version 2>/dev/null || printf 'unknown')"
    else
        printf '  CLI wrapper : %s [not installed]\n' "$AGY_WRAPPER_DEST"
    fi
    if [ -x "$GUI_WRAPPER_DEST" ]; then
        printf '  GUI wrapper : %s [installed] (%s)\n' "$GUI_WRAPPER_DEST" "$("$GUI_WRAPPER_DEST" --proxy-launcher-version 2>/dev/null || printf 'unknown')"
    else
        printf '  GUI wrapper : %s [not installed]\n' "$GUI_WRAPPER_DEST"
    fi
    printf '  which agy   : %s\n' "$(command -v agy 2>/dev/null || printf '<not on PATH>')"

    printf '\n=== Proxy config ===\n'
    if [ -f "$CONF_FILE" ]; then
        printf '  %s:\n' "$CONF_FILE"
        sed 's/^/    /' "$CONF_FILE"
    else
        printf '  %s [not set; auto-probes 7897 -> 7890 -> 10809]\n' "$CONF_FILE"
    fi

    printf '\n=== Desktop entry ===\n'
    if [ -f "$USER_DESKTOP" ]; then
        printf '  %s [present]\n' "$USER_DESKTOP"
        grep -E '^\s*(Exec|X-Antigravity-Pulse-Managed)=' "$USER_DESKTOP" | sed 's/^/    /' || true
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
    elif [ -f "$USER_DESKTOP" ] && grep -q 'antigravity-proxy' "$USER_DESKTOP"; then
        rm -f -- "$USER_DESKTOP"
        printf 'Removed user desktop override: %s\n' "$USER_DESKTOP"
        removed=1
    fi

    if command -v update-desktop-database >/dev/null 2>&1 && [ -d "$USER_APPS_DIR" ]; then
        update-desktop-database "$USER_APPS_DIR" 2>/dev/null || true
    fi

    if [ "$removed" -eq 0 ]; then
        printf 'Nothing to uninstall.\n'
    else
        printf 'Uninstall complete. Config (if any) kept at %s\n' "$CONF_FILE"
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

do_install() {
    mkdir -p -- "$BIN_DIR"

    install -m 0755 "$SCRIPT_DIR/proxy-wrapper.sh" "$AGY_WRAPPER_DEST"
    install -m 0755 "$SCRIPT_DIR/proxy-wrapper.sh" "$GUI_WRAPPER_DEST"
    printf 'Installed CLI wrapper : %s\n' "$AGY_WRAPPER_DEST"
    printf 'Installed GUI wrapper : %s\n' "$GUI_WRAPPER_DEST"

    if [ -n "$PROXY_URL" ]; then
        mkdir -p -- "$CONF_DIR"
        printf '# Proxy address for agy and antigravity-proxy (URL or port)\n%s\n' "$PROXY_URL" > "$CONF_FILE"
        printf 'Wrote proxy config    : %s -> %s\n' "$CONF_FILE" "$PROXY_URL"
    fi

    # Decide whether to ensure loopback debug flags for Antigrative Dashboard.
    local want_debug="no"
    if [ "$DEBUG_PORT_MODE" = "yes" ]; then
        want_debug="yes"
    elif [ "$DEBUG_PORT_MODE" = "auto" ] && [ -d "$HOME/.gemini/config/plugins/antigravity-pulse" ]; then
        want_debug="yes"
        printf '[info] Detected antigravity-pulse plugin; ensuring loopback debug flags on desktop entry.\n'
    fi

    # Locate source .desktop entry (prefer existing user override so we preserve its flags/markers).
    local src_desktop=""
    if [ -f "$USER_DESKTOP" ]; then
        src_desktop="$USER_DESKTOP"
        if ! grep -q 'antigravity-proxy' "$USER_DESKTOP" && [ ! -f "$DESKTOP_BACKUP" ]; then
            mkdir -p -- "$CONF_DIR"
            cp -p -- "$USER_DESKTOP" "$DESKTOP_BACKUP"
        fi
    else
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
    else
        printf '[WARN] No system antigravity.desktop found in /usr/share/applications or /usr/local/share/applications.\n'
        printf '       You can launch desktop Antigravity directly via: %s\n' "$GUI_WRAPPER_DEST"
    fi

    # Check PATH ordering for CLI wrapper.
    printf '\n'
    case ":${PATH:-}:" in
        *":$BIN_DIR:"*)
            local resolved
            resolved="$(command -v agy 2>/dev/null || true)"
            if [ "$resolved" = "$AGY_WRAPPER_DEST" ]; then
                printf '[OK] PATH already resolves agy -> %s\n' "$resolved"
            else
                printf '[WARN] agy currently resolves to: %s\n' "${resolved:-<none>}"
                printf '       Put %s BEFORE other PATH entries in ~/.bashrc or ~/.zshrc:\n' "$BIN_DIR"
                printf '         export PATH="$HOME/.local/bin:$PATH"\n'
            fi
            ;;
        *)
            printf '[NOTE] %s is not in PATH. Add this line to ~/.bashrc (or ~/.zshrc):\n' "$BIN_DIR"
            printf '         export PATH="$HOME/.local/bin:$PATH"\n'
            ;;
    esac
}

case "$MODE" in
    install)   do_install ;;
    status)    show_status ;;
    uninstall) do_uninstall ;;
esac
