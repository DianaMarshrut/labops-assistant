#!/usr/bin/env bash
# labops-install v1.0.0 -- Claude Code server installer
#
# Installs on a fresh Ubuntu 22.04 / 24.04 / 26.04 VPS:
#   - labops user (dedicated, non-login-privileged)
#   - Node.js 22 + Python 3.12+ + Claude Code CLI
#   - Assistant: telegram gateway -> systemd unit labops-assistant
#
# После установки оператор один раз входит под labops (`su - labops`, затем `claude`)
# и авторизует Claude Code; Telegram подключает сам агент (см. global CLAUDE.md).
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
# Версии Ubuntu, на которых установщик прогнан целиком. Гайд на сайте обещает
# все три -- список здесь должен совпадать с гайдом, иначе установка падает на шаге 0.
readonly SUPPORTED_UBUNTU=("22.04" "24.04" "26.04")

REPO_DIR=""
# Интерпретатор для venv ассистента: python3.12 на 22.04, системный python3 на остальных.
PYTHON_BIN="python3"

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

    local supported_list="${SUPPORTED_UBUNTU[*]}"
    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Unsupported OS: ID=${ID:-unknown}. Ubuntu ${supported_list// / or } required."
    fi

    local v supported="no"
    for v in "${SUPPORTED_UBUNTU[@]}"; do
        [[ "${VERSION_ID:-}" == "$v" ]] && supported="yes"
    done
    if [[ "$supported" == "yes" ]]; then
        ok "Ubuntu ${VERSION_ID} detected."
    elif [[ "${LABOPS_ALLOW_UNTESTED_UBUNTU:-0}" == "1" ]]; then
        warn "Ubuntu ${VERSION_ID:-?} is untested. Continuing (LABOPS_ALLOW_UNTESTED_UBUNTU=1)."
    else
        die "Ubuntu ${VERSION_ID:-?} is untested. Require ${supported_list// / or }," \
            "or set LABOPS_ALLOW_UNTESTED_UBUNTU=1."
    fi

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

    # Python 3.12: native on Ubuntu 24.04 (26.04 ships newer). On 22.04 we need
    # deadsnakes PPA because the default python3 is 3.10 and we require Python 3.12+.
    # shellcheck disable=SC1091
    . /etc/os-release
    case "${VERSION_ID:-}" in
        22.04)
            # Сначала чиним сервер после прошлых версий установщика: они делали
            # python3.12 системным python3, а на 22.04 это ломает apt_pkg --
            # unattended-upgrades (автообновления безопасности) и add-apt-repository.
            _restore_system_python3_2204
            if ! command -v python3.12 >/dev/null 2>&1; then
                log "Adding deadsnakes PPA for Python 3.12 (Ubuntu 22.04)."
                add-apt-repository -y ppa:deadsnakes/ppa >/dev/null
                apt_get update -qq
            fi
            apt_get install -y -qq python3.12 python3.12-venv python3.12-dev python3-pip
            # Системный python3 (3.10) не трогаем: 3.12 нужен только venv ассистента.
            PYTHON_BIN="python3.12"
            ;;
        *)
            apt_get install -y -qq python3 python3-venv python3-pip python3-dev
            ;;
    esac

    local py_ver
    py_ver=$("$PYTHON_BIN" --version 2>&1 | awk '{print $2}')
    ok "Base packages installed (assistant python=${py_ver})."
}

# Возвращает /usr/bin/python3 к python3.10 из пакета, если прошлая версия
# установщика переключила его на 3.12 через update-alternatives.
_restore_system_python3_2204() {
    if ! update-alternatives --query python3 2>/dev/null \
            | grep -q '^Alternative: /usr/bin/python3.12$'; then
        return 0
    fi
    warn "System python3 was switched to 3.12 by an older labops-install -- restoring python3.10."
    update-alternatives --remove-all python3 >/dev/null 2>&1 || true
    # --remove-all удаляет и саму ссылку /usr/bin/python3; переустановка пакета её вернёт.
    apt_get install -y -qq --reinstall python3-minimal
    if ! python3 -c 'import apt_pkg' 2>/dev/null; then
        warn "python3 still cannot import apt_pkg -- check /usr/bin/python3 manually."
    fi
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
    # venv от прежних версий установщика смотрит на /usr/bin/python3. На 22.04 тот
    # был 3.12, а после восстановления системного 3.10 venv теряет pip и пакеты --
    # пересоздаём, если версия интерпретатора в venv не та, что нужна ассистенту.
    if [[ -x "${venv}/bin/python" ]]; then
        local py_ver_cmd='import sys; print("%d.%d" % sys.version_info[:2])'
        local want_ver have_ver
        want_ver=$("$PYTHON_BIN" -c "$py_ver_cmd")
        have_ver=$("${venv}/bin/python" -c "$py_ver_cmd" 2>/dev/null || echo "none")
        if [[ "$want_ver" != "$have_ver" ]]; then
            warn "Assistant venv uses Python ${have_ver}, need ${want_ver} -- recreating."
            rm -rf -- "$venv"
        fi
    fi
    if [[ ! -x "${venv}/bin/python" ]]; then
        as_labops "$PYTHON_BIN" -m venv "$venv"
    fi
    if [[ -f "${dir}/requirements.txt" ]]; then
        as_labops "${venv}/bin/pip" install --upgrade pip --quiet
        as_labops "${venv}/bin/pip" install -r "${dir}/requirements.txt" --quiet
    fi

    # gateway config.json. Holds telegram_bot_token and allowlist_user_ids inline.
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
    # Inject the token and owner id via jq. Values may be empty if the
    # operator skipped the prompt -- agent fills them in later.
    # Ключи должны совпадать с тем, что читает gateway.py: telegram_bot_token и
    # allowlist_user_ids. С прежними bot_token/allowed_user_ids сервис падал
    # с «No telegram token», а владелец оказывался вне списка доступа.
    local patched
    patched=$(mktemp)
    TMPFILES+=("$patched")
    local id_arg="null"
    [[ -n "$TG_USER_ID" ]] && id_arg="[${TG_USER_ID}]"
    # Повторный запуск (им же чинится сервер после старых версий) не должен стирать
    # уже подключённого бота: если токен/ID не заданы через env, берём их из
    # текущего config.json, в том числе из прежних ключей bot_token/allowed_user_ids.
    local existing_cfg="${dir}/config.json"
    if [[ -f "$existing_cfg" ]]; then
        if [[ -z "$ASSISTANT_BOT_TOKEN" ]]; then
            ASSISTANT_BOT_TOKEN=$(jq -r '.agents.assistant
                | if (.telegram_bot_token // "") != "" then .telegram_bot_token
                  else (.bot_token // "") end' "$existing_cfg" 2>/dev/null || true)
        fi
        if [[ -z "$TG_USER_ID" ]]; then
            local old_ids
            old_ids=$(jq -c 'if ((.allowlist_user_ids // []) | length) > 0
                then .allowlist_user_ids else (.allowed_user_ids // []) end' \
                "$existing_cfg" 2>/dev/null || echo "[]")
            [[ -n "$old_ids" && "$old_ids" != "[]" ]] && id_arg="$old_ids"
        fi
    fi
    jq --arg tok "$ASSISTANT_BOT_TOKEN" --argjson ids "${id_arg}" \
       '.agents.assistant.telegram_bot_token = $tok | .allowlist_user_ids = ($ids // [])' \
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
# STEP 7: GLOBAL ~/.claude/ (OAuth creds + global settings)
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
# STEP 8: SUDOERS (passwordless narrow-scope for agent self-repair)
# =============================================================================

install_sudoers() {
    step 8 "Granting labops narrow passwordless sudo"

    local sudoers_file="/etc/sudoers.d/labops-agents"
    local tmp
    tmp=$(mktemp)
    TMPFILES+=("$tmp")

    # apt сюда намеренно не входит: `sudo apt` без пароля -- это root
    # (apt -o APT::Update::Pre-Invoke::=<команда> выполняет что угодно), а агент
    # работает без подтверждений и управляется из Telegram. Пакеты ставит владелец.
    # Каждую команду systemctl разрешаем в двух написаниях юнита (с .service и без):
    # sudoers сверяет аргументы буквально, и агент упирался в запрос пароля.
    local unit cmd systemctl_cmds=""
    for unit in labops-assistant labops-assistant.service; do
        for cmd in start stop restart status is-active enable disable "enable --now"; do
            systemctl_cmds+="    /usr/bin/systemctl ${cmd} ${unit}, \\"$'\n'
        done
    done

    cat > "$tmp" <<SUDOERS
# labops-install v${LABOPS_VERSION} -- passwordless sudo for 'labops'.
# Scope: systemctl + journalctl for the agent unit only. No package management.

Cmnd_Alias LABOPS_SYSTEMCTL = \\
${systemctl_cmds}    /usr/bin/systemctl daemon-reload

Cmnd_Alias LABOPS_JOURNAL = \\
    /usr/bin/journalctl -u labops-assistant, \\
    /usr/bin/journalctl -u labops-assistant *, \\
    /usr/bin/journalctl -u labops-assistant.service, \\
    /usr/bin/journalctl -u labops-assistant.service *

${LABOPS_USER} ALL=(root) NOPASSWD: LABOPS_SYSTEMCTL, LABOPS_JOURNAL
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
# STEP 9: MEMORY ROTATION SCRIPTS + CRON
# =============================================================================

# Install the 5 memory-rotation scripts into the assistant workspace and register
# them with labops's crontab. A healthy agent has rotate-warm / trim-hot /
# compress-warm / ov-session-sync / memory-rotate on cron.
install_memory_cron() {
    step 9 "Installing memory-rotation scripts + cron"

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
# STEP 10: SYSTEMD ENABLE (do not start yet -- OAuth + tokens required first)
# =============================================================================

enable_services() {
    step 10 "Enabling systemd services (and starting if OAuth is already set up)"

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
    cat <<EOF

$(printf '%b' "$C_GREEN")================================================================================
  labops-install v${LABOPS_VERSION} complete.
================================================================================$(printf '%b' "$C_NC")

Установлено:
  - Пользователь: ${LABOPS_USER} (${LABOPS_HOME})
  - Claude Code:  ${LABOPS_HOME}/.local/bin/claude
  - Ассистент:    ${LABOPS_HOME}/${ASSISTANT_DIR_NAME}  (labops-assistant.service)

Далее следуйте инструкции из гайда.

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
    install_sudoers
    install_memory_cron
    enable_services
    final_instructions
}

main "$@"
