#!/usr/bin/env bash
# Windows in Docker (dockur/windows) launcher.  All settings live in .env
#
#   bash setup.sh            start / apply .env changes
#   bash setup.sh status     show container state, memory, disk, recent log
#   bash setup.sh logs       follow the live log (download progress is here)
#   bash setup.sh dns        test DNS (host + container) - use when download says 'resolve hostname'
#   bash setup.sh stop       stop Windows
#   bash setup.sh reset      DELETE the Windows disk + downloads and start clean
set -u
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 1

step() { echo "▶ $*"; }
ok()   { echo "✔ $*"; }
warn() { echo "⚠ $*"; }
die()  { echo "✖ $*" >&2; exit 1; }
line() { echo "------------------------------------------------------------------"; }

CMD="${1:-start}"
KVM_DEV="${KVM_DEV:-/dev/kvm}"

# ---------------------------------------------------------------
# helpers
# ---------------------------------------------------------------
find_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found in this environment."
  if docker info >/dev/null 2>&1; then DOCKER=(docker)
  elif sudo -n docker info >/dev/null 2>&1; then DOCKER=(sudo docker)
  else die "Cannot talk to the Docker daemon (is it running? permissions?)."; fi
}

load_env() {
  if [ ! -f .env ]; then
    [ -f .env.example ] || die ".env not found (and no .env.example to copy)."
    cp .env.example .env && ok "Created .env from .env.example"
  fi
  # Safe .env parser: values are taken literally (no $ expansion, no code execution).
  local l k v
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    [[ "$l" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    k="${BASH_REMATCH[1]}"; v="${BASH_REMATCH[2]}"
    case "$k" in WIN_*) ;; *) continue ;; esac
    v="${v#"${v%%[![:space:]]*}"}"
    if [[ "$v" =~ ^\"(.*)\"[[:space:]]*(#.*)?$ ]]; then v="${BASH_REMATCH[1]}"
    elif [[ "$v" =~ ^\'(.*)\'[[:space:]]*(#.*)?$ ]]; then v="${BASH_REMATCH[1]}"
    else v="${v%%#*}"; v="${v%"${v##*[![:space:]]}"}"; fi
    printf -v "$k" '%s' "$v"
  done < .env
  : "${WIN_VERSION:=11}" "${WIN_LANGUAGE:=English}" "${WIN_USERNAME:=Docker}" "${WIN_PASSWORD:=admin}"
  : "${WIN_RAM:=auto}" "${WIN_CPU:=auto}" "${WIN_STORAGE_DIR:=/tmp/windows}" "${WIN_DISK_SIZE:=64G}"
  : "${WIN_CONNECTIONS:=4}" "${WIN_MIDO:=Y}" "${WIN_ESD:=Y}" "${WIN_VERIFY:=N}" "${WIN_REMOVE:=Y}"
  : "${WIN_WEB_PORT:=8006}" "${WIN_RDP_PORT:=3389}" "${WIN_KEEPALIVE:=Y}"
  : "${WIN_NETWORK:=bridge}" "${WIN_RESTART:=unless-stopped}" "${WIN_RAM_FORCE:=N}"
  [ "${WIN_DNS+x}" ] || WIN_DNS="8.8.8.8 1.1.1.1"
  : "${WIN_REGION:=}" "${WIN_KEYBOARD:=}" "${WIN_SHARED_DIR:=}" "${WIN_ISO_URL:=}" "${WIN_LOCAL_ISO:=}"
}

# print one YAML env line, safely quoted ($ must be doubled for compose)
yenv() {
  local v="${2//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//\$/\$\$}"
  printf '      %s: "%s"\n' "$1" "$v"
}

# ---------------------------------------------------------------
# sub-commands that don't need a full start
# ---------------------------------------------------------------
case "$CMD" in
  logs)   find_docker; exec "${DOCKER[@]}" logs -f --tail 50 windows ;;
  dns)
    find_docker; load_env
    H="software.download.prss.microsoft.com"
    line; echo "DNS test for $H"; line
    if getent hosts "$H" >/dev/null 2>&1; then ok "Codespace (host) can resolve it."
    else warn "Codespace (host) can NOT resolve it -> network/DNS problem of the Codespace itself. Try: restart the Codespace."; fi
    echo "Host /etc/resolv.conf:"; sed 's/^/   /' /etc/resolv.conf
    echo; echo "Testing from a throw-away container on Docker's default bridge (same path Windows uses):"
    for d in "" 8.8.8.8 1.1.1.1; do
      if [ -z "$d" ]; then A=(); L="Docker default DNS"; else A=(--dns "$d"); L="--dns $d"; fi
      if "${DOCKER[@]}" run --rm "${A[@]}" busybox nslookup "$H" >/dev/null 2>&1; then ok "container + $L : OK"
      else warn "container + $L : FAILED"; fi
    done
    line
    echo "Current .env: WIN_DNS=\"${WIN_DNS}\"  WIN_NETWORK=\"${WIN_NETWORK}\""
    echo "Use the DNS that shows OK in WIN_DNS, then: bash setup.sh"
    exit 0 ;;
  stop)   find_docker; "${DOCKER[@]}" stop windows && ok "Windows stopped. Start again with: bash setup.sh"; exit 0 ;;
  status)
    find_docker; load_env
    line
    "${DOCKER[@]}" ps -a --filter name=windows --format 'Container: {{.Names}} | {{.Status}} | {{.Ports}}'
    RUN=$("${DOCKER[@]}" inspect -f '{{.State.Running}}' windows 2>/dev/null || echo none)
    echo
    case "$RUN" in
      true)
        if curl -fsS -o /dev/null --max-time 5 "http://localhost:${WIN_WEB_PORT}"; then
          ok "Windows viewer answers on localhost:${WIN_WEB_PORT}."
          echo "   If the forwarded link in the browser is still blank, it is only a PORT FORWARDING problem:"
          echo "   - PORTS tab -> right-click 8006 -> 'Open in Browser' (new tab, stay logged in to GitHub)"
          echo "   - or delete the 8006 row and click 'Forward a Port' -> 8006 again"
          echo "   - or open the https://<codespace>-8006.app.github.dev link printed by setup.sh"
        else
          warn "Container is running but the viewer is not answering yet (still starting? wait 1-2 min)."
        fi ;;
      false)
        warn "Windows container is STOPPED -> a forwarded port then opens nothing (that is what you saw)."
        "${DOCKER[@]}" inspect -f '   exit code: {{.State.ExitCode}} | OOM-killed: {{.State.OOMKilled}} | stopped at: {{.State.FinishedAt}}' windows
        echo "   Start it again with:  bash setup.sh"
        echo "   (exit 0 / 'signal 15' in the log = it was stopped normally, e.g. the Codespace stopped/restarted)" ;;
      *) warn "No 'windows' container exists. Run: bash setup.sh" ;;
    esac
    if [ -e "$WIN_STORAGE_DIR/data.img" ]; then ok "Windows disk found in $WIN_STORAGE_DIR (install progress is kept)."
    else warn "No Windows disk (data.img) in $WIN_STORAGE_DIR -> next start downloads + installs from scratch."; fi
    echo; free -h | head -2; echo
    df -h "$WIN_STORAGE_DIR" 2>/dev/null | tail -2
    echo; echo "Storage dir: $WIN_STORAGE_DIR"; ls -lh "$WIN_STORAGE_DIR" 2>/dev/null | head -15
    line; echo "Recent log:"; "${DOCKER[@]}" logs --tail 20 windows 2>&1
    line
    if "${DOCKER[@]}" logs --tail 60 windows 2>&1 | grep -qiE 'resolve|name resolution'; then
      warn "DNS problem inside the container (cannot resolve hostnames). Run: bash setup.sh dns"
      echo "   then set a working DNS in .env (WIN_DNS) / WIN_NETWORK=\"bridge\" and run: bash setup.sh"
    elif "${DOCKER[@]}" logs --tail 60 windows 2>&1 | grep -qiE 'fail|error|retry|unable|denied|blocked'; then
      warn "Log has errors/retries. If it is the DOWNLOAD step, try in .env (one at a time):"
      echo "   1) WIN_CONNECTIONS=\"1\""
      echo "   2) WIN_MIDO=\"N\"   (or WIN_ESD=\"N\")"
      echo "   3) WIN_VERSION=\"10\"  (different download path)"
      echo "   4) WIN_ISO_URL=\"<direct link to your own ISO>\""
      echo "   then: bash setup.sh reset"
    fi
    exit 0 ;;
  reset)
    find_docker; load_env
    case "$WIN_STORAGE_DIR" in
      ""|/|/tmp|/tmp/|/workspaces|/workspaces/|"$HOME"|"$HOME"/)
        die "Refusing to delete '$WIN_STORAGE_DIR' (it holds other files). Set WIN_STORAGE_DIR to a dedicated folder like /tmp/windows and delete files manually." ;;
    esac
    warn "This DELETES the Windows disk and downloads in: $WIN_STORAGE_DIR"
    read -r -p "Type YES to continue: " A
    [ "$A" = "YES" ] || die "Cancelled."
    "${DOCKER[@]}" rm -f windows >/dev/null 2>&1
    rm -rf "${WIN_STORAGE_DIR:?}"/* "${WIN_STORAGE_DIR:?}"/.[!.]* 2>/dev/null
    ok "Storage cleaned. Starting fresh..."
    CMD="start" ;;
  start) ;;
  *) die "Unknown command '$CMD'. Use: start | status | logs | stop | reset" ;;
esac

# ===============================================================
#  START
# ===============================================================
echo "▶ Starting Windows container setup..."; line

find_docker
if [ ! -e "$KVM_DEV" ]; then
  die "$KVM_DEV is missing. This Codespace has no hardware virtualization.
   Create a new Codespace with a bigger machine (4-core or more). Check: ls -l /dev/kvm"
fi
[ -w "$KVM_DEV" ] || sudo -n chmod 666 "$KVM_DEV" 2>/dev/null || warn "$KVM_DEV is not writable and chmod failed."
ok "Docker and KVM look fine."

load_env
ok "Settings loaded from .env"

# --- version (accept old names like win11 / win10) ---
VERSION_FINAL="${WIN_VERSION#win}"
[ -n "$WIN_ISO_URL" ] && VERSION_FINAL="$WIN_ISO_URL"

# --- resources ---
TOTAL_GB="${TOTAL_GB_OVERRIDE:-$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)}"
CORES=$(nproc)
# Max RAM that is safe to give Windows: the Codespace itself (VS Code, terminal, port
# forwarding, Docker) needs ~6GB. If the machine runs out of memory EVERYTHING gets killed
# (terminal stops, ports vanish, Windows is shut down).
MAX_SAFE=$(( TOTAL_GB - 6 )); [ "$MAX_SAFE" -lt 4 ] && MAX_SAFE=4
case "$WIN_RAM" in
  auto) R=$(( TOTAL_GB - 7 )); [ "$R" -lt 4 ] && R=4; RAM_FINAL="${R}G" ;;
  half) R=$(( TOTAL_GB / 2 )); [ "$R" -lt 4 ] && R=4; RAM_FINAL="${R}G" ;;
  max)  RAM_FINAL="${MAX_SAFE}G" ;;
  *)    RAM_FINAL="$WIN_RAM" ;;
esac
if [[ "$RAM_FINAL" =~ ^[0-9]+G$ ]] && [ "${RAM_FINAL%G}" -gt "$MAX_SAFE" ] && [ "$WIN_RAM_FORCE" != "Y" ]; then
  warn "WIN_RAM=$RAM_FINAL is too much for a ${TOTAL_GB}GB Codespace -> lowering to ${MAX_SAFE}G."
  warn "(Out of memory = terminal/ports/Windows get killed. Override with WIN_RAM_FORCE=\"Y\" at your own risk.)"
  RAM_FINAL="${MAX_SAFE}G"
fi
if [ "$WIN_CPU" = "auto" ]; then
  C=$(( CORES > 2 ? CORES - 1 : CORES )); CPU_FINAL="$C"
else CPU_FINAL="$WIN_CPU"; fi

# --- storage ---
mkdir -p "$WIN_STORAGE_DIR" || die "Cannot create WIN_STORAGE_DIR=$WIN_STORAGE_DIR"
AVAIL_GB=$(df -BG --output=avail "$WIN_STORAGE_DIR" | tail -1 | tr -dc '0-9')
if [ -n "$WIN_SHARED_DIR" ]; then mkdir -p "$WIN_SHARED_DIR"; fi
if [ "$WIN_STORAGE_DIR" != "/tmp" ] && [ -e /tmp/data.img ]; then
  warn "/tmp/data.img exists (an older Windows disk). To reuse it set WIN_STORAGE_DIR=\"/tmp\" in .env"
fi

# --- optional local ISO ---
if [ -n "$WIN_LOCAL_ISO" ] && [ ! -f "$WIN_LOCAL_ISO" ]; then
  die "WIN_LOCAL_ISO=$WIN_LOCAL_ISO not found."
fi

echo "  Machine : ${TOTAL_GB}GB RAM, ${CORES} cores"
echo "  Windows : $VERSION_FINAL | $WIN_LANGUAGE | RAM $RAM_FINAL | CPU $CPU_FINAL | disk $WIN_DISK_SIZE"
echo "  Storage : $WIN_STORAGE_DIR  (${AVAIL_GB}GB free)"
if [[ "$WIN_DISK_SIZE" =~ ^[0-9]+G$ ]] && [ "${WIN_DISK_SIZE%G}" -ge "${AVAIL_GB:-0}" ]; then
  warn "WIN_DISK_SIZE=$WIN_DISK_SIZE is >= free space (${AVAIL_GB}GB). Use a smaller value (64G is enough) so the disk can never fill up."
fi
if [ "${AVAIL_GB:-0}" -lt 35 ]; then
  warn "Less than 35GB free in the storage folder. ISO (~8GB) + Windows install may run out of space."
  warn "Pick a folder on a bigger disk in .env (WIN_STORAGE_DIR)."
fi
line
if ! getent hosts software.download.prss.microsoft.com >/dev/null 2>&1; then
  warn "This Codespace cannot resolve software.download.prss.microsoft.com right now."
  warn "Run: bash setup.sh dns   (if host also fails: restart the Codespace)"
fi

# ---------------------------------------------------------------
# keep-alive (once)
# ---------------------------------------------------------------
if [ "$WIN_KEEPALIVE" = "Y" ]; then
  chmod +x keep-alive.sh
  if [ -f keep-alive.pid ] && kill -0 "$(cat keep-alive.pid)" 2>/dev/null; then
    ok "Keep-alive already running (pid $(cat keep-alive.pid))."
  else
    nohup setsid ./keep-alive.sh >/dev/null 2>&1 &
    echo $! > keep-alive.pid
    ok "Keep-alive started (pid $(cat keep-alive.pid))."
  fi
fi

# ---------------------------------------------------------------
# generate compose.yaml from .env
# ---------------------------------------------------------------
step "Generating compose.yaml from .env ..."
{
  echo "# AUTO-GENERATED by setup.sh from .env - do not edit, edit .env instead."
  echo "services:"
  echo "  windows:"
  echo "    image: dockurr/windows"
  echo "    container_name: windows"
  echo "    devices:"
  echo "      - $KVM_DEV:/dev/kvm"
  [ -e /dev/net/tun ] && echo "      - /dev/net/tun"
  echo "    cap_add:"
  echo "      - NET_ADMIN"
  echo "    ports:"
  echo "      - \"$WIN_WEB_PORT:8006\""
  echo "      - \"$WIN_RDP_PORT:3389/tcp\""
  echo "      - \"$WIN_RDP_PORT:3389/udp\""
  echo "    stop_grace_period: 2m"
  case "$WIN_RESTART" in no|always|unless-stopped|on-failure|on-failure:[0-9]*) R_POL="$WIN_RESTART" ;; *) R_POL="unless-stopped" ;; esac
  echo "    restart: $R_POL"
  if [ "$WIN_NETWORK" = "bridge" ]; then echo "    network_mode: bridge"; fi
  if [ -n "$WIN_DNS" ]; then
    echo "    dns:"
    for d in ${WIN_DNS//,/ }; do
      [[ "$d" =~ ^[0-9a-fA-F:.]+$ ]] && echo "      - $d"
    done
  fi
  echo "    environment:"
  yenv VERSION     "$VERSION_FINAL"
  yenv LANGUAGE    "$WIN_LANGUAGE"
  [ -n "$WIN_REGION" ]   && yenv REGION   "$WIN_REGION"
  [ -n "$WIN_KEYBOARD" ] && yenv KEYBOARD "$WIN_KEYBOARD"
  yenv USERNAME    "$WIN_USERNAME"
  yenv PASSWORD    "$WIN_PASSWORD"
  yenv RAM_SIZE    "$RAM_FINAL"
  yenv CPU_CORES   "$CPU_FINAL"
  yenv DISK_SIZE   "$WIN_DISK_SIZE"
  yenv CONNECTIONS "$WIN_CONNECTIONS"
  yenv MIDO        "$WIN_MIDO"
  yenv ESD         "$WIN_ESD"
  yenv VERIFY      "$WIN_VERIFY"
  yenv REMOVE      "$WIN_REMOVE"
  echo "    volumes:"
  echo "      - \"$WIN_STORAGE_DIR:/storage\""
  [ -n "$WIN_SHARED_DIR" ] && echo "      - \"$WIN_SHARED_DIR:/shared\""
  [ -n "$WIN_LOCAL_ISO" ]  && echo "      - \"$WIN_LOCAL_ISO:/custom.iso\""
} > compose.yaml
ok "compose.yaml created."

# ---------------------------------------------------------------
# start
# ---------------------------------------------------------------
step "Starting the Windows container..."
if ! "${DOCKER[@]}" compose up -d; then
  line; die "docker compose failed. See the error above."
fi

step "Waiting for the web viewer (port 8006)..."
READY=0
for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 3 "http://localhost:$WIN_WEB_PORT"; then READY=1; break; fi
  sleep 3
done
sleep 5
line
if [ "$("${DOCKER[@]}" inspect -f '{{.State.Running}}' windows 2>/dev/null)" != "true" ]; then
  warn "The Windows container is NOT running. Last log lines:"
  "${DOCKER[@]}" logs --tail 30 windows 2>&1
  die "Container stopped. Share the log above to debug."
fi
[ "$READY" = 1 ] && ok "Container is up, web viewer answering." || warn "Port $WIN_WEB_PORT not answering yet - check: bash setup.sh logs"
step "Watching the first minute for download errors..."
BAD=0
for _ in $(seq 1 12); do
  sleep 5
  if "${DOCKER[@]}" logs --since 90s windows 2>&1 | grep -qE 'ERROR'; then BAD=1; break; fi
done
echo; echo "Latest log:"; "${DOCKER[@]}" logs --tail 12 windows 2>&1 | cut -c1-200
line
if [ "$BAD" = 1 ]; then
  warn "The container log shows an ERROR (probably the ISO download)."
  if "${DOCKER[@]}" logs --since 90s windows 2>&1 | grep -qiE 'resolve|name resolution'; then
    echo "   It is a DNS problem. Run:  bash setup.sh dns   and put a working DNS in .env (WIN_DNS)."
  else
    echo "   Run:  bash setup.sh status   for hints (WIN_CONNECTIONS / WIN_MIDO / WIN_ESD / WIN_ISO_URL)."
  fi
  line
else
  ok "No errors in the first minute."
fi
echo "Windows ISO download + install is automatic (15-40 min). Do NOT stop the Codespace."
echo "Watch progress:   bash setup.sh logs     |   health: bash setup.sh status"
echo "Open the viewer:"
echo "  1) VS Code 'PORTS' tab -> if $WIN_WEB_PORT is missing: 'Forward a Port' -> $WIN_WEB_PORT -> globe icon"
if [ -n "${CODESPACE_NAME:-}" ]; then
  echo "  2) or: https://${CODESPACE_NAME}-${WIN_WEB_PORT}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}"
fi
echo "Login (after install): user '$WIN_USERNAME'"
