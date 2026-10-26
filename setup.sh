#!/usr/bin/env bash
# Installer and controls for Kiro Crew public access. Linux and macOS.
#
#   ./setup.sh [install]   validate .env, install kc-auth, start everything
#   ./setup.sh down        stop everything and keep it off after a reboot
#   ./setup.sh up          start everything again
#   ./setup.sh status      what is running, and whether it starts at boot
#
# install:
#   1. validates .env
#   2. writes allowlist/authenticated-emails.txt from ALLOWED_EMAILS
#      (ALLOWED_DOMAINS goes to oauth2-proxy and kc-auth directly)
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
ALLOWLIST_PATH="$REPO_DIR/allowlist/authenticated-emails.txt"

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
Environment="GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID"
Environment="ALLOWLIST_FILE=$ALLOWLIST_PATH"
Environment="ALLOWED_DOMAINS=$ALLOWED_DOMAINS"
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
    <key>GOOGLE_CLIENT_ID</key>
    <string>$(xml_escape "$GOOGLE_CLIENT_ID")</string>
    <key>ALLOWLIST_FILE</key>
    <string>$(xml_escape "$ALLOWLIST_PATH")</string>
    <key>ALLOWED_DOMAINS</key>
    <string>$(xml_escape "$ALLOWED_DOMAINS")</string>
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
             CLOUDFLARE_TUNNEL_TOKEN; do
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

  ALLOWED_EMAILS="${ALLOWED_EMAILS:-}"
  ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-}"
  [[ "$ALLOWED_EMAILS" != *REPLACE_ME* ]] || die "ALLOWED_EMAILS still has its REPLACE_ME placeholder"
  [[ -n "${ALLOWED_EMAILS//[[:space:],]/}" || -n "${ALLOWED_DOMAINS//[[:space:],]/}" ]] \
    || die "set ALLOWED_EMAILS or ALLOWED_DOMAINS in .env; with neither, nobody can log in"
  check_allowed_domains

  KIROCREW_PORT="${KIROCREW_PORT:-5476}"
  KC_AUTH_PORT="${KC_AUTH_PORT:-3000}"
  TOKEN_TTL="${TOKEN_TTL:-8h}"
}

# docker compose passes ALLOWED_DOMAINS to oauth2-proxy exactly as written in
# .env, so it is checked here rather than normalized.
check_allowed_domains() {
  [[ -n "$ALLOWED_DOMAINS" ]] || return 0
  local domains domain
  domains=()
  IFS=',' read -ra domains <<<"$ALLOWED_DOMAINS"
  for domain in ${domains[@]+"${domains[@]}"}; do
    [[ -z "$domain" ]] && continue
    [[ "$domain" == *\** ]] && die "ALLOWED_DOMAINS must not contain *: it would let any Google account in"
    [[ "$domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || die "ALLOWED_DOMAINS: '$domain' is not a lowercase domain like example.com (no @, spaces or leading dot)"
  done
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
  for name in kc-oauth2-proxy kc-login-redirect kc-cloudflared; do
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
  info "Writing $ALLOWLIST_PATH"
  local emails email
  mkdir -p "$(dirname "$ALLOWLIST_PATH")"
  chmod 755 "$(dirname "$ALLOWLIST_PATH")"  # the oauth2-proxy container user must list it
  {
    echo "# Generated by setup.sh from ALLOWED_EMAILS in .env. Whole domains"
    echo "# (ALLOWED_DOMAINS in .env) are not listed here."
    echo "# Edit this file to add or remove someone; it takes effect within"
    echo "# seconds, no restart. Also update ALLOWED_EMAILS in .env, because"
    echo "# './setup.sh install' rewrites this file from it."
    emails=()
    IFS=',' read -ra emails <<<"$ALLOWED_EMAILS"
    for email in ${emails[@]+"${emails[@]}"}; do
      email="$(echo "$email" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
      [[ -z "$email" ]] && continue
      [[ "$email" == *@*.* ]] || die "not an email address in ALLOWED_EMAILS: $email"
      echo "$email"
    done
  } > "$ALLOWLIST_PATH.new"
  mv "$ALLOWLIST_PATH.new" "$ALLOWLIST_PATH"
  chmod 644 "$ALLOWLIST_PATH"  # the oauth2-proxy container user must read it
  # Before the folder mount, the allowlist lived at the repo root.
  rm -f authenticated-emails.txt
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
  local route_url="http://localhost:4180"
  if [[ "$OS" == mac ]]; then
    route_url="http://oauth2-proxy:4180"
  fi
  cat <<EOF

Cloudflare tunnel Public Hostname service URL for this machine:
  $route_url

Remaining manual step (Kiro Crew blocks agents from editing this file):
  In ~/.kiro/crew/config.json set   "dashboard": { "url": "https://${DOMAIN}" }
  then run:  kirocrew restart

Then open https://${DOMAIN} and sign in with an allowed Google account.
It lands you in the dashboard with no token to paste.
EOF
}

main() {
  cd "$REPO_DIR"
  case "$(uname -s)" in
    Linux)  OS=linux ;;
    Darwin) OS=mac ;;
    *) die "unsupported OS $(uname -s): Linux and macOS only" ;;
  esac

  local cmd="${1:-install}"
  case "$cmd" in
    install) cmd_install ;;
    up)      cmd_up ;;
    down)    cmd_down ;;
    status)  cmd_status ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

usage() {
  cat <<'EOF'
Usage: ./setup.sh [command]

  install   (default) validate .env, install kc-auth, start everything and
            turn on start-at-boot. Re-run after changing .env.
  down      stop kc-auth, oauth2-proxy and cloudflared, and keep them off
            after a reboot. Your URL stops working until `up`.
  up        start everything again after `down`, and turn start-at-boot
            back on. Does not reinstall; run `install` after editing .env.
  status    show what is running and whether it will start at boot.
EOF
}

cmd_install() {
  load_env
  check_prerequisites
  select_compose_files
  write_allowlist
  if [[ "$OS" == mac ]]; then install_kc_auth_mac; else install_kc_auth_linux; fi
  wait_for_kc_auth
  info "Starting oauth2-proxy and cloudflared"
  docker compose up -d
  print_next_steps
  check_boot_readiness
}

# up/down need only the values docker compose interpolates, not validation.
load_env_for_compose() {
  [[ -f .env ]] || die "no .env file. Run ./setup.sh install first."
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  KC_AUTH_PORT="${KC_AUTH_PORT:-3000}"
}

cmd_down() {
  load_env_for_compose
  info "Stopping oauth2-proxy and cloudflared"
  # `down` removes the containers, so their restart policy cannot bring them
  # back at boot; `up` recreates them.
  docker compose down
  info "Stopping kc-auth and turning off its start-at-boot"
  if [[ "$OS" == mac ]]; then
    launchctl bootout "gui/$(id -u)/$LAUNCHD_LABEL" 2>/dev/null || true
    launchctl disable "gui/$(id -u)/$LAUNCHD_LABEL"
  else
    systemctl --user disable --now "$UNIT_NAME" 2>/dev/null || true
  fi
  info "Down. https://${DOMAIN:-<DOMAIN>} is offline until: ./setup.sh up"
  echo "    (The Kiro Crew gateway itself keeps running; this stops only the public access.)"
}

cmd_up() {
  load_env_for_compose
  if [[ "$OS" == mac ]]; then
    [[ -f "$LAUNCHD_PLIST" ]] || die "kc-auth is not installed. Run ./setup.sh install"
    local domain
    domain="gui/$(id -u)"
    launchctl enable "$domain/$LAUNCHD_LABEL"
    launchctl bootstrap "$domain" "$LAUNCHD_PLIST" 2>/dev/null || true  # already loaded is fine
    launchctl kickstart -k "$domain/$LAUNCHD_LABEL"
  else
    [[ -f "$UNIT_DIR/$UNIT_NAME" ]] || die "kc-auth is not installed. Run ./setup.sh install"
    systemctl --user enable --now "$UNIT_NAME"
  fi
  wait_for_kc_auth
  info "Starting oauth2-proxy and cloudflared"
  docker compose up -d
  info "Up. https://${DOMAIN:-<DOMAIN>} is online."
  check_boot_readiness
}

cmd_status() {
  load_env_for_compose
  echo "kc-auth:"
  if [[ "$OS" == mac ]]; then
    if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then echo "  loaded in launchd"; else echo "  not loaded"; fi
  else
    echo "  $(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true), start-at-boot: $(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)"
  fi
  if curl -fsS --max-time 2 "http://127.0.0.1:${KC_AUTH_PORT}/kc-auth/health" >/dev/null 2>&1; then
    echo "  health: ok"
  else
    echo "  health: not answering on 127.0.0.1:${KC_AUTH_PORT}"
  fi
  echo "containers:"
  docker compose ps --format '{{.Name}}: {{.Status}}' 2>/dev/null | sed 's/^/  /' | grep . || echo "  none running"
  if [[ -n "${DOMAIN:-}" ]]; then
    echo "public URL:"
    echo "  https://$DOMAIN -> HTTP $(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://$DOMAIN/" || echo '???') (302 = up, sends you to Google login)"
  fi
  check_boot_readiness
}

# Report every piece that must start on its own for the URL to work after a
# reboot. Warnings only: each fix needs the user (sudo, or an app setting).
check_boot_readiness() {
  echo
  info "Start-at-boot check"
  local ok=1
  if [[ "$OS" == linux ]]; then
    if [[ "$(systemctl is-enabled docker 2>/dev/null || true)" != enabled ]] \
       && [[ "$(systemctl is-enabled docker.socket 2>/dev/null || true)" != enabled ]]; then
      warn "Docker does not start at boot. Fix: sudo systemctl enable docker"; ok=0
    fi
    if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || echo no)" != yes ]]; then
      warn "user lingering is off, so kc-auth waits for you to log in. Fix: sudo loginctl enable-linger $USER"; ok=0
    fi
    if [[ "$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)" != enabled ]]; then
      warn "kc-auth start-at-boot is off (after ./setup.sh down). Fix: ./setup.sh up"; ok=0
    fi
    if [[ "$(systemctl --user is-enabled kirocrew.service 2>/dev/null || true)" != enabled ]] \
       && [[ "$(systemctl is-enabled kirocrew.service 2>/dev/null || true)" != enabled ]]; then
      warn "the Kiro Crew gateway is not a boot service, so the URL shows errors until you start it. Fix: kirocrew service install"; ok=0
    fi
  else
    if ! launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
      warn "kc-auth is not loaded (after ./setup.sh down). Fix: ./setup.sh up"; ok=0
    fi
    if [[ ! -f "$HOME/Library/LaunchAgents/dev.kirocrew.gateway.plist" ]] \
       && [[ ! -f "/Library/LaunchDaemons/dev.kirocrew.gateway.plist" ]]; then
      warn "the Kiro Crew gateway is not a launchd service, so it will not start on its own. Fix: kirocrew service install"; ok=0
    fi
    echo "    macOS: kc-auth and the gateway start when you LOG IN, not at power-on."
    echo "    For a Mac that should come up unattended, turn on automatic login"
    echo "    (System Settings > Users & Groups) and set Docker Desktop to start at"
    echo "    login (Docker Desktop > Settings > General)."
  fi
  if [[ "$ok" == 1 ]]; then
    echo "    Everything this script can check starts at boot."
  fi
}

# Run only when executed, so the render functions can be sourced and tested.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
