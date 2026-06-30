#!/usr/bin/env bash
# labops-install v1.0.0 -- Claude Code server installer
#
# Installs on a fresh Ubuntu 22.04 / 24.04 VPS:
#   - labops user (dedicated, non-login-privileged)
#   - Node.js 22 + Python 3.12 + Claude Code CLI
#   - Assistant: telegram gateway -> systemd unit labops-assistant
#
# Operator runs `sudo -u labops claude login` once after install finishes.
#
# Usage:
#   curl -fsSL https://labopsai.pro/install | sudo bash
#   # or
#   sudo ./install.sh

set -euo pipefail

# =============================================================================
# CONSTANTS
# =============================================================================

readonly LABOPS_VERSION="1.0.0"
readonly LABOPS_REPO="https://github.com/DianaMarshrut/labops-assistant.git"
readonly LABOPS_REF="${LABOPS_INSTALL_REF:-main}"
readonly ASSISTANT_DIR_NAME="labops-assistant"
readonly NODE_MAJOR="22"
readonly LABOPS_USER="labops"
readonly LABOPS_HOME="/home/labops"
readonly CURL_OPTS=(-fsSL --max-time 60 --retry 2 --retry-delay 3)

REPO_DIR=""

# =============================================================================
# TERMINAL OUTPUT
# =============================================================================

if [[ -t 1 ]]; then
    C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
    C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
    C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi

log()  { printf '%b[%s]%b %s\n' "$C_BLUE" "$(date +%H:%M:%S)" "$C_NC" "$*"; }
ok()   { printf '%b✓%b %s\n' "$C_GREEN" "$C_NC" "$*"; }
warn() { printf '%b!%b %s\n' "$C_YELLOW" "$C_NC" "$*" >&2; }
err()  { printf '%b✗%b %s\n' "$C_RED" "$C_NC" "$*" >&2; }
die()  { err "$*"; exit 1; }

step() {
    local n="$1"; shift
    printf '\n%b== Step %s: %s ==%b\n' "$C_BOLD" "$n" "$*" "$C_NC"
}

banner() {
    printf '\n%b' "$C_YELLOW"
    cat <<'EOF'
   _          _    ___
  | |    __ _| |__/ _ \ _ __  ___
  | |   / _` | '_ \ | | | '_ \/ __|
  | |__| (_| | |_) | |_| | |_) \__ \
  |_____\__,_|_.__/\___/| .__/|___/
                        |_|
            LabOps Install -- AI-операционка на вашем VPS
EOF
    printf '%b\n' "$C_NC"
}

# =============================================================================
# HELPERS
# =============================================================================

apt_get() {
    local tries=0
    local max_tries=20
    while fuser /var/lib/dpkg/lock-frontend &>/dev/null || fuser /var/lib/apt/lists/lock &>/dev/null; do
        ((tries++))
        if (( tries > max_tries )); then
            die "Another apt/dpkg process holds the lock for too long. Aborting."
        fi
        sleep 3
    done
    DEBIAN_FRONTEND=noninteractive apt-get "$@"
}

# Tmp tracking + cleanup trap.
TMPFILES=()
TMPDIRS=()
_cleanup() {
    local f d
    for f in "${TMPFILES[@]:-}"; do
        [[ -n "$f" && -f "$f" ]] && rm -f "$f" || true
    done
    for d in "${TMPDIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf "$d" || true
    done
}
trap _cleanup EXIT

is_noninteractive() {
    [[ "${LABOPS_NONINTERACTIVE:-0}" == "1" ]] || [[ ! -t 0 ]]
}

# prompt_or_env VAR ENV_NAME "prompt" [default] [--secret]
# shellcheck disable=SC2034  # out_ref is a nameref, writes propagate to caller
prompt_or_env() {
    local -n out_ref=$1
    local env_name=$2
    local prompt=$3
    local default=${4:-}
    local secret=${5:-}
    local env_val="${!env_name:-}"

    if [[ -n "$env_val" ]]; then
        out_ref="$env_val"
        return 0
    fi

    if is_noninteractive; then
        if [[ -n "$default" ]]; then
            out_ref="$default"
            return 0
        fi
        die "Non-interactive mode: required value ${env_name} is missing (prompt was: ${prompt})."
    fi

    local answer=""
    if [[ -n "$default" ]]; then
        prompt="${prompt} [${default}]"
    fi
    prompt="${prompt}: "

    if [[ "$secret" == "--secret" ]]; then
        read -r -s -p "$prompt" answer </dev/tty
        echo ""
    else
        read -r -p "$prompt" answer </dev/tty
    fi

    if [[ -z "$answer" && -n "$default" ]]; then
        answer="$default"
    fi
    out_ref="$answer"
}

# Simple {{KEY}} -> VALUE substitution from template file into dst.
# Usage: render_template src dst KEY1 VAL1 [KEY2 VAL2 ...]
render_template() {
    local src=$1 dst=$2; shift 2
    [[ -f "$src" ]] || die "Template not found: $src"

    local tmp
    tmp=$(mktemp)
    cp "$src" "$tmp"

    while (($# >= 2)); do
        local key="$1" val="$2"; shift 2
        # Use python for safe literal replace (no regex surprises in values).
        python3 - "$tmp" "{{${key}}}" "$val" <<'PY'
import sys, pathlib
path, needle, repl = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
p.write_text(p.read_text().replace(needle, repl))
PY
    done

    mv "$tmp" "$dst"
}

as_labops() {
    sudo -u "$LABOPS_USER" -H -- env -C "$LABOPS_HOME" "$@"
}

# Install a file at dst owned by a specific user, 0600 by default.
install_as_user() {
    local src=$1 dst=$2 owner=$3 mode=${4:-0600}
    install -m "$mode" -o "$owner" -g "$owner" "$src" "$dst"
}

# write_as_user: copy SRC to DST owned by LABOPS_USER. Works even when SRC is
# a root-owned 0600 mktemp file that labops cannot read.
write_as_user() {
    local src="$1" dst="$2" mode="${3:-0644}"
    local dst_dir
    dst_dir=$(dirname "$dst")
    if [[ ! -d "$dst_dir" ]]; then
        install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "$dst_dir"
    fi
    install -o "$LABOPS_USER" -g "$LABOPS_USER" -m "$mode" "$src" "$dst"
}

# fix_owner: recursively chown to labops (-h affects symlinks).
fix_owner() {
    local path="$1"
    [[ -e "$path" ]] || return 0
    chown -RhP "${LABOPS_USER}:${LABOPS_USER}" "$path"
}

# ---------------------------------------------------------------------------
# Repo sourcing
# ---------------------------------------------------------------------------

ensure_repo() {
    if [[ -n "$REPO_DIR" && -d "$REPO_DIR" ]]; then
        echo "$REPO_DIR"; return 0
    fi
    local dir
    dir=$(mktemp -d)
    TMPDIRS+=("$dir")
    log "Cloning labops-assistant @ ${LABOPS_REF}..." >&2
    git clone --quiet --depth 1 --branch "$LABOPS_REF" "$LABOPS_REPO" "$dir" \
        || die "Failed to clone ${LABOPS_REPO}"
    REPO_DIR="$dir"
    echo "$dir"
}

validate_tg_token() {
    local token=$1
    # Format: <digits>:<alphanum-dash-underscore>, at least 8:30 chars.
    [[ "$token" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]
}

tg_get_me() {
    local token=$1
    curl "${CURL_OPTS[@]}" "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || true
}

# =============================================================================
# PREFLIGHT
# =============================================================================

preflight() {
    step 0 "Preflight checks"

    if [[ $EUID -ne 0 ]]; then
        die "Run as root: sudo $0"
    fi

    if [[ ! -r /etc/os-release ]]; then
        die "Cannot read /etc/os-release -- unsupported OS."
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ID=${ID:-unknown}. Ubuntu 22.04 or 24.04 required."
    fi

    case "${VERSION_ID:-}" in
        22.04|24.04)
            ok "Ubuntu ${VERSION_ID} detected."
            ;;
        *)
            if [[ "${LABOPS_ALLOW_UNTESTED_UBUNTU:-0}" == "1" ]]; then
                warn "Ubuntu ${VERSION_ID:-?} is untested. Continuing (LABOPS_ALLOW_UNTESTED_UBUNTU=1)."
            else
                die "Ubuntu ${VERSION_ID:-?} is untested. Require 22.04 or 24.04, or set LABOPS_ALLOW_UNTESTED_UBUNTU=1."
            fi
            ;;
    esac

    if ! command -v curl &>/dev/null; then
        log "Bootstrapping curl..."
        apt_get update -qq
        apt_get install -y -qq curl
    fi

    if ! curl "${CURL_OPTS[@]}" -o /dev/null https://api.github.com/ 2>/dev/null; then
        warn "Network check to api.github.com failed. Installer may fail later."
    fi

    if ! command -v git &>/dev/null; then
        apt_get update -qq
        apt_get install -y -qq git
    fi
    ensure_repo
    ok "Preflight passed."
}

# =============================================================================
# STEP 1: APT DEPENDENCIES
# =============================================================================

install_apt_deps() {
    step 1 "Installing apt dependencies"

    apt_get update -qq
    apt_get install -y -qq \
        ca-certificates gnupg lsb-release software-properties-common \
        sudo \
        curl wget git jq rsync \
        build-essential \
        systemd \
        logrotate \
        cron

    # Python 3.12: native on Ubuntu 24.04. On 22.04 we need deadsnakes PPA
    # because the default python3 is 3.10 and we require Python 3.12+.
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${VERSION_ID:-}" in
        22.04)
            if ! command -v python3.12 >/dev/null 2>&1; then
                log "Adding deadsnakes PPA for Python 3.12 (Ubuntu 22.04)."
                add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
                apt_get update -qq
            fi
            apt_get install -y -qq python3.12 python3.12-venv python3.12-dev python3-pip
            # Point /usr/bin/python3 -> python3.12 so `python3 --version` shows 3.12.
            update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 100 >/dev/null 2>&1 || true
            update-alternatives --set python3 /usr/bin/python3.12 >/dev/null 2>&1 || true
            ;;
        24.04|*)
            apt_get install -y -qq python3 python3-venv python3-pip python3-dev
            ;;
    esac

    local py_ver
    py_ver=$(python3 --version 2>&1 | awk '{print $2}')
    ok "Base packages installed (python3=${py_ver})."
}

# =============================================================================
# STEP 2: NODE.JS 22
# =============================================================================

install_node() {
    step 2 "Installing Node.js ${NODE_MAJOR}"

    if command -v node &>/dev/null; then
        local current_major
        current_major=$(node -v 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/')
        if [[ "$current_major" == "$NODE_MAJOR" ]]; then
            ok "Node.js $(node -v) already installed."
            return 0
        fi
        warn "Node.js $(node -v) present but not v${NODE_MAJOR}; replacing."
    fi

    curl "${CURL_OPTS[@]}" "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt_get install -y -qq nodejs
    ok "Node.js $(node -v) installed."
}

# =============================================================================
# STEP 3: CLAUDE CODE CLI
# =============================================================================

install_claude_cli() {
    step 3 "Installing Claude Code CLI (per-user for ${LABOPS_USER})"

    local claude_bin="${LABOPS_HOME}/.local/bin/claude"

    if [[ -x "$claude_bin" ]]; then
        ok "Claude CLI already installed at ${claude_bin}."
        # Best-effort update; never block install on update failure.
        as_labops "$claude_bin" update >/dev/null 2>&1 || warn "claude update non-zero; continuing."
        _ensure_path_export
        return 0
    fi

    local installer_tmp
    installer_tmp=$(mktemp)
    TMPFILES+=("$installer_tmp")

    curl "${CURL_OPTS[@]}" https://claude.ai/install.sh -o "$installer_tmp" \
        || die "Failed to download Claude Code installer."
    chmod 644 "$installer_tmp"

    # Run Anthropic's installer as labops so binary lands at ~/.local/bin/claude.
    as_labops bash "$installer_tmp"

    if [[ ! -x "$claude_bin" ]]; then
        die "Claude CLI install failed -- ${claude_bin} not found."
    fi

    local ver
    ver=$(as_labops "$claude_bin" --version 2>/dev/null || echo "unknown")
    ok "Claude CLI v${ver} installed at ${claude_bin}."

    _ensure_path_export
}

# Expose ~/.local/bin on labops's PATH for non-interactive SSH + systemd.
# .bashrc aborts on non-interactive shells, so prepend before the PS1 guard.
# .profile runs in full for login shells -- append is fine.
_ensure_path_export() {
    local marker='# Added by labops-install: expose ~/.local/bin'
    local export_line='export PATH="$HOME/.local/bin:$PATH"'

    local rc_entry rc placement
    for rc_entry in "${LABOPS_HOME}/.bashrc:prepend" "${LABOPS_HOME}/.profile:append"; do
        rc="${rc_entry%:*}"
        placement="${rc_entry##*:}"

        if [[ ! -f "$rc" ]]; then
            as_labops touch "$rc"
        fi

        if grep -Fq "$marker" "$rc" 2>/dev/null; then
            continue
        fi

        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        if [[ "$placement" == "prepend" ]]; then
            { echo "$marker"; echo "$export_line"; echo ''; cat "$rc"; } >"$tmp"
        else
            { cat "$rc"; echo ''; echo "$marker"; echo "$export_line"; } >"$tmp"
        fi
        install -o "$LABOPS_USER" -g "$LABOPS_USER" -m 0644 "$tmp" "$rc"
    done
}

# =============================================================================
# STEP 4: LABOPS USER
# =============================================================================

ensure_labops_user() {
    step 4 "Ensuring '${LABOPS_USER}' system user"

    if id -u "$LABOPS_USER" &>/dev/null; then
        ok "User '${LABOPS_USER}' already exists."
    else
        useradd --create-home --shell /bin/bash "$LABOPS_USER"
        ok "User '${LABOPS_USER}' created."
    fi

    # Make sure home is usable.
    if [[ ! -d "$LABOPS_HOME" ]]; then
        die "Home dir ${LABOPS_HOME} missing after useradd."
    fi
    chown "${LABOPS_USER}:${LABOPS_USER}" "$LABOPS_HOME"
    chmod 0755 "$LABOPS_HOME"
}

# =============================================================================
# STEP 5: OPERATOR INPUTS
# =============================================================================


collect_inputs() {
    step 5 "Reading operator inputs from env (tokens filled by agent after install)"

    OPERATOR_NAME="${LABOPS_USER_NAME:-friend}"
    OPERATOR_LANGUAGE="${LABOPS_LANGUAGE:-Russian}"
    OPERATOR_TIMEZONE="${LABOPS_TIMEZONE:-Europe/Moscow}"
    ASSISTANT_BOT_TOKEN="${LABOPS_ASSISTANT_BOT_TOKEN:-}"
    ASSISTANT_BOT_USERNAME="${LABOPS_ASSISTANT_BOT_USER:-}"
    TG_USER_ID="${LABOPS_TG_USER_ID:-}"

    ok "Inputs: name=${OPERATOR_NAME}, tz=${OPERATOR_TIMEZONE}, lang=${OPERATOR_LANGUAGE}"
}

# =============================================================================
# STEP 6: INSTALL ASSISTANT
# =============================================================================

install_assistant() {
    step 6 "Installing Assistant (labops-assistant)"

    local repo_dir
    repo_dir=$(ensure_repo)
    local dir="${LABOPS_HOME}/${ASSISTANT_DIR_NAME}"

    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "$dir"
    install -o "$LABOPS_USER" -g "$LABOPS_USER" -m 0644 \
        "${repo_dir}/gateway/gateway.py" "${dir}/gateway.py"
    install -o "$LABOPS_USER" -g "$LABOPS_USER" -m 0644 \
        "${repo_dir}/gateway/requirements.txt" "${dir}/requirements.txt"

    # Virtualenv + requirements
    local venv="${dir}/.venv"
    if [[ ! -x "${venv}/bin/python" ]]; then
        as_labops python3 -m venv "$venv"
    fi
    if [[ -f "${dir}/requirements.txt" ]]; then
        as_labops "${venv}/bin/pip" install --upgrade pip --quiet
        as_labops "${venv}/bin/pip" install -r "${dir}/requirements.txt" --quiet
    fi

    # gateway config.json. Holds bot_token and allowed_user_ids inline.
    # chmod 0600 because it contains a secret.
    local wsroot="${LABOPS_HOME}/.claude-lab/assistant/.claude"
    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" \
        "${LABOPS_HOME}/.claude-lab" \
        "${LABOPS_HOME}/.claude-lab/assistant" \
        "$wsroot"

    local config_tmp
    config_tmp=$(mktemp)
    TMPFILES+=("$config_tmp")
    render_template "${REPO_DIR}/templates/assistant-config.json" "$config_tmp" \
        USER        "$LABOPS_USER" \
        AGENT_NAME  "assistant" \
        USER_NAME   "$OPERATOR_NAME"
    # Inject bot_token and allowed_user_ids via jq. Values may be empty if the
    # operator skipped the prompt -- agent fills them in later.
    local patched
    patched=$(mktemp)
    TMPFILES+=("$patched")
    local id_arg="null"
    [[ -n "$TG_USER_ID" ]] && id_arg="[${TG_USER_ID}]"
    jq --arg tok "$ASSISTANT_BOT_TOKEN" --argjson ids "${id_arg}" \
       '.agents.assistant.bot_token = $tok | .allowed_user_ids = ($ids // [])' \
       "$config_tmp" > "$patched"
    mv "$patched" "$config_tmp"
    install_as_user "$config_tmp" "${dir}/config.json" "$LABOPS_USER" 0600

    # Full agent workspace (CLAUDE.md + core/USER.md + stub cold memory).
    _write_agent_workspace "$wsroot"

    # systemd unit
    local unit_tmp
    unit_tmp=$(mktemp)
    TMPFILES+=("$unit_tmp")
    render_template "${REPO_DIR}/templates/labops-assistant.service" "$unit_tmp" \
        USER "$LABOPS_USER"
    install -m 0644 -o root -g root "$unit_tmp" /etc/systemd/system/labops-assistant.service

    fix_owner "${LABOPS_HOME}/.claude-lab"
    ok "Assistant installed at ${dir}"
}

# _write_agent_workspace <wsroot> -- lays down CLAUDE.md + core/ tree for Assistant.
# Smoke-check: ls ~/.claude-lab/assistant/.claude/ must show CLAUDE.md,
# USER.md (under core/), skills/.
_write_agent_workspace() {
    local ws="$1"

    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" \
        "$ws" \
        "${ws}/core" \
        "${ws}/core/hot" \
        "${ws}/core/warm" \
        "${ws}/skills" \
        "${ws}/logs"

    # CLAUDE.md (top-level)
    local claude_md_tmp
    claude_md_tmp=$(mktemp)
    TMPFILES+=("$claude_md_tmp")
    render_template "${REPO_DIR}/templates/CLAUDE.md" "$claude_md_tmp" \
        AGENT_NAME "Assistant" \
        AGENT_ROLE "operator's daily AI assistant" \
        USER_NAME  "$OPERATOR_NAME" \
        LANGUAGE   "$OPERATOR_LANGUAGE" \
        TIMEZONE   "$OPERATOR_TIMEZONE"
    write_as_user "$claude_md_tmp" "${ws}/CLAUDE.md" 0644

    # core/USER.md -- operator profile
    local user_tmp
    user_tmp=$(mktemp)
    TMPFILES+=("$user_tmp")
    cat > "$user_tmp" <<UEOF
# USER.md -- Operator profile

**Name:** ${OPERATOR_NAME}
**Timezone:** ${OPERATOR_TIMEZONE}
**Preferred language:** ${OPERATOR_LANGUAGE}

## Notes
- Edit this file freely -- the agent reads it on every start.
UEOF
    write_as_user "$user_tmp" "${ws}/core/USER.md" 0644

    # core/rules.md
    local rules_tmp
    rules_tmp=$(mktemp)
    TMPFILES+=("$rules_tmp")
    cat > "$rules_tmp" <<'REOF'
# Rules

- Ask before destructive operations (rm -rf, DROP TABLE, sudo on shared infra).
- Never commit secrets. Never print tokens/keys in plain text.
- On each correction: update LEARNINGS.md so the mistake does not repeat.
- Prefer small, reversible changes.
REOF
    write_as_user "$rules_tmp" "${ws}/core/rules.md" 0644

    # Stub cold memory + hot/warm files so @includes in CLAUDE.md resolve.
    local stub_tmp
    stub_tmp=$(mktemp)
    TMPFILES+=("$stub_tmp")

    printf '# MEMORY.md\n\nLong-term notes.\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/MEMORY.md" 0644

    printf '# LEARNINGS.md\n\nOne line per correction.\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/LEARNINGS.md" 0644

    printf '# recent.md -- full journal (NOT in @include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/hot/recent.md" 0644

    printf '# handoff.md -- last 10 entries (@include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/hot/handoff.md" 0644

    printf '# decisions.md -- last 14 days of decisions (@include)\n' > "$stub_tmp"
    write_as_user "$stub_tmp" "${ws}/core/warm/decisions.md" 0644
}

# =============================================================================
# STEP 8: GLOBAL ~/.claude/ (OAuth creds + global settings)
# =============================================================================

setup_global_claude() {
    step 7 "Setting up ${LABOPS_HOME}/.claude/ (shared OAuth dir)"

    local claude_dir="${LABOPS_HOME}/.claude"
    install -d -m 0700 -o "$LABOPS_USER" -g "$LABOPS_USER" "$claude_dir"
    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "${claude_dir}/plugins"

    local settings_json="${claude_dir}/settings.json"
    if [[ ! -f "$settings_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        cat > "$tmp" <<'SJEOF'
{
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "400000"
  },
  "permissions": {
    "allow": [
      "Bash(npm:*)", "Bash(node:*)", "Bash(git:*)",
      "Bash(python3:*)", "Bash(pip3:*)",
      "Bash(cat:*)", "Bash(ls:*)", "Bash(mkdir:*)",
      "Bash(chmod:*)", "Bash(echo:*)",
      "Read", "Write", "Edit"
    ]
  }
}
SJEOF
        write_as_user "$tmp" "$settings_json" 0644
    fi

    local mcp_json="${claude_dir}/mcp.json"
    if [[ ! -f "$mcp_json" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        echo '{"mcpServers": {}}' > "$tmp"
        write_as_user "$tmp" "$mcp_json" 0644
    fi

    # Global CLAUDE.md -- loaded by every Claude Code session under labops user.
    local global_claude_md="${claude_dir}/CLAUDE.md"
    if [[ ! -f "$global_claude_md" ]]; then
        local tmp
        tmp=$(mktemp)
        TMPFILES+=("$tmp")
        render_template "${REPO_DIR}/templates/global-CLAUDE.md" "$tmp" \
            USER       "$LABOPS_USER" \
            USER_NAME  "$OPERATOR_NAME" \
            TG_ID      "$TG_USER_ID" \
            LANGUAGE   "$OPERATOR_LANGUAGE" \
            TIMEZONE   "$OPERATOR_TIMEZONE"
        write_as_user "$tmp" "$global_claude_md" 0644
    fi

    fix_owner "$claude_dir"
    ok "${claude_dir} ready."
}

# =============================================================================
# STEP 9: SUPERPOWERS PLUGIN
# =============================================================================

install_superpowers() {
    step 8 "Installing Superpowers plugin"

    local repo_dir
    repo_dir=$(ensure_repo)
    local plugins_dir="${LABOPS_HOME}/.claude/plugins"
    local sp_dir="${plugins_dir}/superpowers"
    local cfg="${plugins_dir}/config.json"

    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "$plugins_dir"

    local stage="${sp_dir}.staging.$$"
    rm -rf "$stage" 2>/dev/null || true
    cp -r "${repo_dir}/skills/superpowers" "$stage"
    [[ -d "$sp_dir" ]] && { rm -rf "${sp_dir}.prev" 2>/dev/null || true; mv "$sp_dir" "${sp_dir}.prev"; }
    mv "$stage" "$sp_dir"
    rm -rf "${sp_dir}.prev" 2>/dev/null || true
    fix_owner "$plugins_dir"

    # Defensive jq merge of plugins config.
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")
    local abs_path="$sp_dir"

    if [[ -f "$cfg" ]]; then
        if ! jq -e 'type=="object"' "$cfg" >/dev/null 2>&1; then
            local backup
            backup="${cfg}.bak.$(date +%s)"
            cp "$cfg" "$backup" 2>/dev/null || true
            warn "Existing ${cfg} is not a JSON object -- backed up to $(basename "$backup"); skipping merge."
            fix_owner "$plugins_dir"
            return 0
        fi
        if ! jq --arg p "$abs_path" \
                '.plugins = ((.plugins // {}) + {"superpowers": {"enabled": true, "path": $p}})' \
                "$cfg" > "$tmp" 2>/dev/null; then
            warn "jq merge of plugins config failed -- leaving ${cfg} untouched."
            return 0
        fi
        [[ ! -s "$tmp" ]] && { warn "jq empty output -- skipping."; return 0; }
    else
        if ! jq -n --arg p "$abs_path" \
                '{plugins: {superpowers: {enabled: true, path: $p}}}' > "$tmp" 2>/dev/null; then
            warn "Failed to write initial plugins config -- skipping."
            return 0
        fi
    fi
    write_as_user "$tmp" "$cfg" 0644

    fix_owner "$plugins_dir"
    ok "Superpowers installed at ${sp_dir}"
}

# =============================================================================
# STEP 10: SUDOERS (passwordless narrow-scope for agent self-repair)
# =============================================================================

install_sudoers() {
    step 9 "Granting labops narrow passwordless sudo"

    local sudoers_file="/etc/sudoers.d/labops-agents"
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    cat > "$tmp" <<SUDOERS
# labops-install v${LABOPS_VERSION} -- passwordless sudo for 'labops'.
# Scope: systemctl + journalctl for two agent units, plus apt package mgmt
# (Agent can run 'sudo apt' for self-repair / package install).

Cmnd_Alias LABOPS_SYSTEMCTL = \\
    /usr/bin/systemctl start labops-assistant, \\
    /usr/bin/systemctl stop labops-assistant, \\
    /usr/bin/systemctl restart labops-assistant, \\
    /usr/bin/systemctl status labops-assistant, \\
    /usr/bin/systemctl is-active labops-assistant, \\
    /usr/bin/systemctl enable labops-assistant, \\
    /usr/bin/systemctl disable labops-assistant, \\
    /usr/bin/systemctl daemon-reload

Cmnd_Alias LABOPS_JOURNAL = \\
    /usr/bin/journalctl -u labops-assistant, \\
    /usr/bin/journalctl -u labops-assistant *

Cmnd_Alias LABOPS_APT = \\
    /usr/bin/apt, /usr/bin/apt *, \\
    /usr/bin/apt-get, /usr/bin/apt-get *

${LABOPS_USER} ALL=(root) NOPASSWD: LABOPS_SYSTEMCTL, LABOPS_JOURNAL, LABOPS_APT
SUDOERS

    # Validate syntax before installing -- a broken sudoers can lock out sudo.
    if ! visudo -cf "$tmp" >/dev/null 2>&1; then
        err "Generated sudoers failed visudo -cf syntax check. Aborting install to avoid lockout."
        return 1
    fi

    install -m 0440 -o root -g root "$tmp" "$sudoers_file"
    ok "Sudoers installed at ${sudoers_file} (0440)."
}

# =============================================================================
# STEP 11: MEMORY ROTATION SCRIPTS + CRON
# =============================================================================

# Install the 5 memory-rotation scripts into the assistant workspace and register
# them with labops's crontab. A healthy agent has rotate-warm / trim-hot /
# compress-warm / ov-session-sync / memory-rotate on cron.
install_memory_cron() {
    step 10 "Installing memory-rotation scripts + cron"

    local repo_dir
    repo_dir=$(ensure_repo)
    local scripts_src="${repo_dir}/scripts"

    local scripts_dst="${LABOPS_HOME}/.claude-lab/assistant/scripts"
    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "$scripts_dst"

    local logs_dst="${LABOPS_HOME}/.claude-lab/assistant/logs"
    install -d -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "$logs_dst"

    local name
    local installed=()
    local required=(trim-hot rotate-warm compress-warm ov-session-sync memory-rotate)
    for name in "${required[@]}"; do
        local src="${scripts_src}/${name}.sh"
        if [[ ! -f "$src" ]]; then
            # All 5 jobs must be present. A partial install would leave dead cron
            # entries pointing at missing files -- fail loud so the operator does
            # not ship a half-wired workspace.
            err "Memory script '${name}.sh' missing at ${src} -- refusing partial install."
            return 1
        fi
        install -m 0755 -o "$LABOPS_USER" -g "$LABOPS_USER" "$src" "${scripts_dst}/${name}.sh"
        installed+=("$name")
    done

    # Ensure cron service is enabled + running. On minimal Ubuntu images
    # (LXC, cloud) the cron package is installed but not auto-started.
    systemctl enable --now cron 2>/dev/null \
        || warn "cron service not started -- memory rotation will run after next reboot."

    # Merge cron lines with labops's existing crontab without clobbering it.
    # Marker lets us update on reinstall instead of duplicating entries.
    local marker="# labops-install v${LABOPS_VERSION}: memory rotation"
    local cron_block
    # CRON_TZ pins the schedule to UTC so the jobs fire at the same wall-clock
    # moment regardless of the host's system timezone. HOME= is set because
    # scripts rely on $HOME under `set -u`; on some minimal images cron does not
    # always export HOME to the user's actual home directory.
    cron_block=$(cat <<CRON
${marker}
CRON_TZ=UTC
HOME=${LABOPS_HOME}
30 4 * * * ${scripts_dst}/rotate-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
0 5 * * *  ${scripts_dst}/trim-hot.sh >> ${logs_dst}/memory-cron.log 2>&1
0 6 * * *  ${scripts_dst}/compress-warm.sh >> ${logs_dst}/memory-cron.log 2>&1
30 6 * * * ${scripts_dst}/ov-session-sync.sh >> ${logs_dst}/memory-cron.log 2>&1
0 21 * * * ${scripts_dst}/memory-rotate.sh >> ${logs_dst}/memory-cron.log 2>&1
# labops-install memory rotation end
CRON
)

    local current_tmp new_tmp
    current_tmp=$(mktemp)
    new_tmp=$(mktemp)
    TMPFILES+=("$current_tmp" "$new_tmp")

    # Fetch current crontab (empty is fine on first run).
    crontab -u "$LABOPS_USER" -l 2>/dev/null > "$current_tmp" || true

    # Strip any previous managed block so we can re-insert the current one.
    python3 - "$current_tmp" "$new_tmp" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding='utf-8') as f:
    text = f.read()
cleaned = re.sub(
    r'# labops-install v[0-9.]+: memory rotation.*?# labops-install memory rotation end\n?',
    '',
    text,
    flags=re.DOTALL,
)
open(dst, 'w', encoding='utf-8').write(cleaned.rstrip() + ('\n' if cleaned.strip() else ''))
PY

    # Append new block.
    printf '%s\n' "$cron_block" >> "$new_tmp"

    if ! crontab -u "$LABOPS_USER" "$new_tmp" 2>/dev/null; then
        err "Failed to install crontab for ${LABOPS_USER} -- memory rotation will not run."
        return 1
    fi

    # Verify the block actually landed so a silent crontab discard doesn't slip through.
    if ! crontab -u "$LABOPS_USER" -l 2>/dev/null | grep -q "labops-install memory rotation end"; then
        err "crontab accepted the file but memory-rotation block is not visible on read-back."
        return 1
    fi

    ok "Memory cron installed: ${installed[*]}"
}

# =============================================================================
# STEP 12: SYSTEMD ENABLE (do not start yet -- OAuth + tokens required first)
# =============================================================================

enable_services() {
    step 11 "Enabling systemd services (and starting if OAuth is already set up)"

    systemctl daemon-reload

    local oauth_ready="no"
    if [[ -f "${LABOPS_HOME}/.claude/.credentials.json" ]]; then
        oauth_ready="yes"
    fi

    # Always enable (on-boot auto-start). If tokens are present we also try
    # start -- but only when OAuth credentials exist, otherwise the unit crashes.
    if [[ -n "$ASSISTANT_BOT_TOKEN" ]]; then
        systemctl enable labops-assistant.service --quiet
        if [[ "$oauth_ready" == "yes" ]]; then
            if systemctl start labops-assistant.service 2>/dev/null; then
                ok "labops-assistant enabled + started."
            else
                warn "labops-assistant enabled, but start failed -- check 'journalctl -u labops-assistant'."
            fi
        else
            log "labops-assistant enabled -- will start after OAuth under labops."
        fi
    else
        log "labops-assistant NOT enabled (no token)."
    fi

}

# =============================================================================
# FINAL BANNER
# =============================================================================

final_instructions() {
    local assistant_label="@${ASSISTANT_BOT_USERNAME:-<fill-in>}"
    local tokens_filled="no"
    if [[ -n "$ASSISTANT_BOT_TOKEN" && -n "$TG_USER_ID" ]]; then
        tokens_filled="yes"
    fi

    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  labops-install v${LABOPS_VERSION} complete.  Agent-native flow: the root-Claude
  agent will configure the rest.  Do NOT run commands by hand below.
================================================================================$(printf '%b' "$C_NC")

Installed on this VPS:
  - User:      ${LABOPS_USER} (${LABOPS_HOME})
  - Claude:    ${LABOPS_HOME}/.local/bin/claude  (per-user, on PATH)
  - Assistant: ${LABOPS_HOME}/${ASSISTANT_DIR_NAME}  (systemd: labops-assistant)
  - Plugin:    ${LABOPS_HOME}/.claude/plugins/superpowers/
  - Sudoers:   /etc/sudoers.d/labops-agents  (narrow, 0440)

$(printf '%b' "$C_BOLD")Tokens filled during install:$(printf '%b' "$C_NC") ${tokens_filled}

$(printf '%b' "$C_BOLD")NEXT STEPS -- these are for the root-Claude agent, not the operator:$(printf '%b' "$C_NC")

  $(printf '%b' "$C_YELLOW")1.$(printf '%b' "$C_NC") One-time Anthropic OAuth under labops (interactive -- opens browser):

        sudo -u ${LABOPS_USER} -i bash -lc 'claude login'

      Credentials land in ${LABOPS_HOME}/.claude/ and are shared by both agents.

  $(printf '%b' "$C_YELLOW")2.$(printf '%b' "$C_NC") If tokens were skipped during install, fill them now and restart:

        # Assistant: edit ${LABOPS_HOME}/${ASSISTANT_DIR_NAME}/config.json --
        # set agents.assistant.bot_token and allowed_user_ids=[<your id>]
        sudo systemctl restart labops-assistant
        sudo systemctl status  labops-assistant --no-pager

  $(printf '%b' "$C_YELLOW")3.$(printf '%b' "$C_NC") Smoke-checks:

        id ${LABOPS_USER}                                       # uid >= 1000
        node -v                                                 # v22.x
        python3 --version                                       # 3.12+
        sudo -u ${LABOPS_USER} bash -lc 'which claude'          # ${LABOPS_HOME}/.local/bin/claude
        ls ${LABOPS_HOME}/.claude-lab/assistant/.claude/        # CLAUDE.md, core/, skills/
        systemctl is-active labops-assistant                    # active (after steps 1+2)
        ls -la /etc/sudoers.d/labops-agents                     # exists, 0440
        ls ${LABOPS_HOME}/.claude/plugins/superpowers/skills/ 2>/dev/null | wc -l

  $(printf '%b' "$C_YELLOW")4.$(printf '%b' "$C_NC") Operator talks to Assistant in Telegram: ${assistant_label}

EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    banner
    preflight
    install_apt_deps
    install_node
    ensure_labops_user
    install_claude_cli
    collect_inputs
    install_assistant
    setup_global_claude
    install_superpowers
    install_sudoers
    install_memory_cron
    enable_services
    final_instructions
}

main "$@"
