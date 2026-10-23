#!/usr/bin/env bash
# One-shot installer for Kiro Crew public access. Linux and macOS.
#
#   1. validates .env
#   2. writes authenticated-emails.txt from ALLOWED_EMAILS
#   3. installs kc-auth as a host service (it must run on the host: see the
#      comment at the top of docker-compose.yml)
#        Linux: systemd user service   ~/.config/systemd/user/kc-auth.service
#        macOS: launchd agent          ~/Library/LaunchAgents/<label>.plist
#   4. starts oauth2-proxy + cloudflared with docker compose
#        macOS adds docker-compose.mac.yml (no host networking on Docker Desktop)
#
# Safe to re-run after editing .env. Written for bash 3.2 (macOS's /bin/bash).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

UNIT_NAME="kc-auth.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
LAUNCHD_LABEL="com.kc-remote-access.kc-auth"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/$LAUNCHD_LABEL.plist"
LAUNCHD_LOG="$HOME/Library/Logs/kc-auth.log"
MAC_COMPOSE_FILE="docker-compose.yml:docker-compose.mac.yml"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

# Escape a value for an XML text node.
xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
  printf '%s' "$s"
}

# Back up *path* when its content differs from *new*, then write *new*.
replace_file() {
  local path="$1" new="$2"
  if [[ -f "$path" ]] && [[ "$(cat "$path")" != "$new" ]]; then
    local backup
    backup="$path.bak.$(date +%Y%m%d%H%M%S)"
    cp "$path" "$backup"
    info "Existing $(basename "$path") backed up to $backup"
  fi
  printf '%s\n' "$new" > "$path"
}

render_systemd_unit() {
  cat <<EOF
# Installed by $REPO_DIR/setup.sh
[Unit]
Description=Kiro Crew token API (behind oauth2-proxy)
After=network.target

[Service]
ExecStart="$NODE_BIN" "$REPO_DIR/kc-auth/server.js"
Environment="PORT=$KC_AUTH_PORT"
Environment="TOKEN_TTL=$TOKEN_TTL"
Environment="KIROCREW_BIN=$KIROCREW_BIN"
Restart=on-failure

[Install]
WantedBy=default.target
EOF
}

render_launchd_plist() {
  # launchd starts agents with a minimal PATH, so put node's and kirocrew's
  # directories first for anything kirocrew launches.
  local path_value
  path_value="$(dirname "$NODE_BIN"):$(dirname "$KIROCREW_BIN"):/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Installed by $(xml_escape "$REPO_DIR")/setup.sh -->
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LAUNCHD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "$NODE_BIN")</string>
    <string>$(xml_escape "$REPO_DIR/kc-auth/server.js")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PORT</key>
    <string>$(xml_escape "$KC_AUTH_PORT")</string>
    <key>TOKEN_TTL</key>
    <string>$(xml_escape "$TOKEN_TTL")</string>
    <key>KIROCREW_BIN</key>
    <string>$(xml_escape "$KIROCREW_BIN")</string>
    <key>PATH</key>
    <string>$(xml_escape "$path_value")</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>$(xml_escape "$LAUNCHD_LOG")</string>
  <key>StandardErrorPath</key>
  <string>$(xml_escape "$LAUNCHD_LOG")</string>
</dict>
</plist>
EOF
}

load_env() {
  [[ -f .env ]] || die "no .env file. Run: cp .env.example .env  and fill it in."
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a

  local var value
  for var in DOMAIN GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET OAUTH2_COOKIE_SECRET \
             CLOUDFLARE_TUNNEL_TOKEN ALLOWED_EMAILS; do
    value="${!var:-}"
    [[ -n "$value" ]] || die "$var is empty in .env"
    [[ "$value" != *REPLACE_ME* ]] || die "$var still has its REPLACE_ME placeholder"
  done
  # shellcheck disable=SC2153  # DOMAIN is set by sourcing .env
  [[ "$DOMAIN" != "crew.example.com" ]] || die "DOMAIN is still the example value"

  # oauth2-proxy accepts 16, 24 or 32 bytes, raw or (URL-safe) base64-encoded.
  local raw_len b64 dec_len
  raw_len="$(printf '%s' "$OAUTH2_COOKIE_SECRET" | wc -c | tr -d ' ')"
  b64="$(printf '%s' "$OAUTH2_COOKIE_SECRET" | tr -- '-_' '+/')"
  while (( ${#b64} % 4 )); do b64="$b64="; done
  dec_len="$(printf '%s' "$b64" | base64 -d 2>/dev/null | wc -c | tr -d ' ' || echo 0)"
  case " $raw_len $dec_len " in
    *" 16 "*|*" 24 "*|*" 32 "*) ;;
    *) die "OAUTH2_COOKIE_SECRET must be 16, 24 or 32 bytes. Generate one with: openssl rand -base64 32 | tr -- '+/' '-_'" ;;
  esac

  KIROCREW_PORT="${KIROCREW_PORT:-5476}"
  KC_AUTH_PORT="${KC_AUTH_PORT:-3000}"
  TOKEN_TTL="${TOKEN_TTL:-8h}"
}

check_prerequisites() {
  command -v docker >/dev/null || die "docker is not installed"
  docker compose version >/dev/null 2>&1 || die "the docker compose plugin is not installed"

  if [[ "$OS" == mac ]]; then
    command -v launchctl >/dev/null || die "launchctl not found"
    # docker-compose.mac.yml uses `!reset`, added in Compose 2.24.
    local v major minor
    v="$(docker compose version --short 2>/dev/null | sed 's/^v//')"
    major="${v%%.*}"; minor="$(echo "$v" | cut -d. -f2)"
    if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
       && (( major < 2 || (major == 2 && minor < 24) )); then
      die "Docker Compose $v is too old; 2.24 or newer is needed. Update Docker Desktop."
    fi
  else
    command -v systemctl >/dev/null || die "systemd is required to run kc-auth"
  fi

  NODE_BIN="$(command -v node || true)"
  [[ -n "$NODE_BIN" ]] || die "node is not installed (Node.js 18 or newer is required)"
  "$NODE_BIN" -e 'process.exit(+process.versions.node.split(".")[0] >= 18 ? 0 : 1)' \
    || die "Node.js 18 or newer is required (found $("$NODE_BIN" --version))"

  KIROCREW_BIN="${KIROCREW_BIN:-$(command -v kirocrew || true)}"
  [[ -n "$KIROCREW_BIN" && -x "$KIROCREW_BIN" ]] \
    || die "kirocrew not found. Install Kiro Crew, or set KIROCREW_BIN in .env"

  # Any HTTP response counts: the gateway answers 401 without a token.
  if ! curl -sS -o /dev/null --max-time 5 "http://127.0.0.1:${KIROCREW_PORT}/" 2>/dev/null; then
    warn "no Kiro Crew gateway answered on 127.0.0.1:${KIROCREW_PORT}. Start it (kirocrew start) or fix KIROCREW_PORT."
  fi

  # Another stack that already owns these container names would clash.
  local name project
  for name in kc-oauth2-proxy kc-cloudflared; do
    project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
    if [[ -n "$project" && "$project" != "kc-remote-access" ]]; then
      die "container $name already exists from compose project '$project'. Stop that stack first (docker compose down in its directory)."
    fi
  done
}

# On a Mac, make every later `docker compose` command in this directory use
# the Mac override too, by recording COMPOSE_FILE in .env.
select_compose_files() {
  [[ "$OS" == mac ]] || return 0
  if [[ "${COMPOSE_FILE:-}" != "$MAC_COMPOSE_FILE" ]]; then
    grep -q '^COMPOSE_FILE=' .env \
      && die "COMPOSE_FILE in .env must be $MAC_COMPOSE_FILE on macOS"
    printf '\n# Added by setup.sh on macOS: use the Mac compose override.\nCOMPOSE_FILE=%s\n' \
      "$MAC_COMPOSE_FILE" >> .env
    info "Added COMPOSE_FILE=$MAC_COMPOSE_FILE to .env"
  fi
  export COMPOSE_FILE="$MAC_COMPOSE_FILE"
}

write_allowlist() {
  info "Writing authenticated-emails.txt"
  local emails email
  {
    echo "# Generated by setup.sh from ALLOWED_EMAILS in .env."
    echo "# You may edit this file directly; oauth2-proxy reloads it on save."
    IFS=',' read -ra emails <<<"$ALLOWED_EMAILS"
    for email in "${emails[@]}"; do
      email="$(echo "$email" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      [[ -z "$email" ]] && continue
      [[ "$email" == *@*.* ]] || die "not an email address in ALLOWED_EMAILS: $email"
      echo "$email"
    done
  } > authenticated-emails.txt.new
  mv authenticated-emails.txt.new authenticated-emails.txt
  chmod 644 authenticated-emails.txt  # the oauth2-proxy container user must read it
}

install_kc_auth_linux() {
  info "Installing $UNIT_NAME (systemd user service)"
  mkdir -p "$UNIT_DIR"
  replace_file "$UNIT_DIR/$UNIT_NAME" "$(render_systemd_unit)"
  systemctl --user daemon-reload
  systemctl --user enable "$UNIT_NAME" >/dev/null
  systemctl --user restart "$UNIT_NAME"
}

install_kc_auth_mac() {
  info "Installing $LAUNCHD_LABEL (launchd agent)"
  mkdir -p "$(dirname "$LAUNCHD_PLIST")" "$(dirname "$LAUNCHD_LOG")"
  replace_file "$LAUNCHD_PLIST" "$(render_launchd_plist)"
  plutil -lint "$LAUNCHD_PLIST" >/dev/null || die "generated plist is invalid: $LAUNCHD_PLIST"
  local domain
  domain="gui/$(id -u)"
  launchctl bootout "$domain/$LAUNCHD_LABEL" 2>/dev/null || true
  launchctl bootstrap "$domain" "$LAUNCHD_PLIST"
  launchctl enable "$domain/$LAUNCHD_LABEL"
  launchctl kickstart -k "$domain/$LAUNCHD_LABEL"
}

wait_for_kc_auth() {
  info "Waiting for kc-auth on 127.0.0.1:${KC_AUTH_PORT}"
  local healthy=0 _
  for _ in $(seq 1 20); do
    if curl -fsS --max-time 2 "http://127.0.0.1:${KC_AUTH_PORT}/kc-auth/health" >/dev/null 2>&1; then
      healthy=1; break
    fi
    sleep 0.5
  done
  if [[ "$healthy" != 1 ]]; then
    if [[ "$OS" == mac ]]; then
      die "kc-auth did not become healthy. Check: tail -n 50 $LAUNCHD_LOG"
    fi
    die "kc-auth did not become healthy. Check: journalctl --user -u $UNIT_NAME -n 50"
  fi
}

print_next_steps() {
  echo
  info "Done. kc-auth, oauth2-proxy and cloudflared are running."
  if [[ "$OS" == linux ]] \
     && [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != "yes" ]]; then
    warn "user lingering is off, so kc-auth stops when you log out and does not start at boot."
    warn "To keep it running: sudo loginctl enable-linger $USER"
  fi
  local route_url="http://localhost:4180"
  if [[ "$OS" == mac ]]; then
    route_url="http://oauth2-proxy:4180"
    cat <<EOF

macOS notes:
  - kc-auth runs while you are logged in to this Mac and starts at login.
  - Docker Desktop must be running, and set to start at login, for the
    containers to come back after a reboot.
EOF
  fi
  cat <<EOF

Cloudflare tunnel Public Hostname service URL for this machine:
  $route_url

Remaining manual step (Kiro Crew blocks agents from editing this file):
  In ~/.kiro/crew/config.json set   "dashboard": { "url": "https://${DOMAIN}" }
  then run:  kirocrew restart

Then open https://${DOMAIN} and sign in with an allowed Google account.
Token for the dashboard: https://${DOMAIN}/kc-auth/token
EOF
}

main() {
  cd "$REPO_DIR"
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=mac ;;
    *) die "unsupported OS $(uname -s): Linux and macOS only" ;;
  esac

  load_env
  check_prerequisites
  select_compose_files
  write_allowlist
  if [[ "$OS" == mac ]]; then install_kc_auth_mac; else install_kc_auth_linux; fi
  wait_for_kc_auth
  info "Starting oauth2-proxy and cloudflared"
  docker compose up -d
  print_next_steps
}

# Run only when executed, so the render functions can be sourced and tested.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
