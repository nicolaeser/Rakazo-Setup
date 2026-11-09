#!/usr/bin/env bash
# Rakazo – sets up and checks the Docker Compose deployment in /opt/rakazo.
#
#   ./generate-env.sh           Create or update the deployment interactively: .env, the Compose
#                               files, the optional Postfix mail server, /etc/caddy/Caddyfile and
#                               the DNS records to set. Secrets and custom entries are kept,
#                               replaced files are backed up.
#   ./generate-env.sh --owner   Create the admin account with a password (stack must be running)
#   ./generate-env.sh --check   Check the deployment, Caddy, mail and DNS; with the stack running
#                               also health, host check, accounts, computers, screen proxy and CORS
#   ./generate-env.sh --deactivate EMAIL
#                               Lock an account: ends its sign-ins, computers and runs (edge)
#   ./generate-env.sh --reactivate EMAIL
#                               Unlock it again (edge)
#   --dir DIR                   Deployment directory for all of the above (default /opt/rakazo)
#
# Run it from the git checkout. It copies docker-compose.yml (with the mail server also the hooks
# in postfix/) to the deployment directory and writes .env there. .env holds secrets, domain,
# ports and options; everything else is fixed in docker-compose.yml and takes precedence there.
# RAKAZO_CADDYFILE=FILE manages another file than /etc/caddy/Caddyfile.

set -euo pipefail
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
  { echo "Error: Bash 4.4 or newer required." >&2; exit 1; }
shopt -u patsub_replacement 2>/dev/null || true

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DEPLOY_DIR=/opt/rakazo
DIR_OPT=""         # " --dir DIR" for printed commands when DEPLOY_DIR is not the default
CADDY_FILE=${RAKAZO_CADDYFILE:-/etc/caddy/Caddyfile}
ENV_FILE=.env
DEFAULT_WEB_PORT=5173
DEFAULT_API_PORT=3100
CADDY_EXAMPLE_URL=https://github.com/nicolaeser/Rakazo-Setup/blob/main/Caddyfile.example
INBOUND_EMAIL_DOCS=https://github.com/elie222/rakazo/blob/main/docs/self-host-inbound-email.md
# Caddy's certificates as the package stores them; Postfix mounts this folder at /tls.
CADDY_CERTS=/var/lib/caddy/.local/share/caddy/certificates
LE_STORE=acme-v02.api.letsencrypt.org-directory
STAMP=$(date +%Y%m%d-%H%M%S)
OWNER_USER=${SUDO_USER:-$(id -un)}

# Managed by this script.
MANAGED_KEYS=(
  RAKAZO_HOST WEB_ORIGIN BETTER_AUTH_URL API_URL
  RAKAZO_BIND RAKAZO_WEB_PORT RAKAZO_API_PORT TRUSTED_PROXIES SANDBOX_IDLE_MS
  POSTGRES_PASSWORD DATABASE_URL DATABASE_MIGRATION_URL
  BETTER_AUTH_SECRET ENCRYPTION_KEY SCREEN_PROXY_SECRET SANDBOX_SUPERVISOR_TOKEN
  SIGNUPS_ENABLED SIGNUP_ALLOWLIST RAKAZO_ADMIN_EMAILS
  EMAIL_PROVIDER EMAIL_API_KEY SMTP_URL EMAIL_FROM
  OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_NAME OIDC_ALLOW_SIGNUP_BYPASS
  COMPOSIO_API_KEY PIPEDREAM_CLIENT_ID PIPEDREAM_CLIENT_SECRET PIPEDREAM_PROJECT_ID PIPEDREAM_ENVIRONMENT
  PI_DEFAULT_PROVIDER PI_DEFAULT_MODEL PI_DEFAULT_CREDENTIALS OPENROUTER_API_KEY ANTHROPIC_API_KEY
  DEEPSEEK_API_KEY RAKAZO_LOCAL_MODELS_URL RAKAZO_LOCAL_MODELS RAKAZO_LOCAL_VISION_MODELS
  RAKAZO_LOCAL_CONTEXT_WINDOW RAKAZO_LOCAL_MAX_TOKENS RAKAZO_LOCAL_MODELS_API_KEY RAKAZO_IMAGE_TAG
  SCIM_BEARER_TOKEN INBOUND_EMAIL_DOMAIN INBOUND_EMAIL_SECRET
  COMPOSE_PROFILES
)
# Read only by edge until the release after v0.8.0.
EDGE_KEYS=(SCIM_BEARER_TOKEN INBOUND_EMAIL_DOMAIN INBOUND_EMAIL_SECRET RAKAZO_LOCAL_MODELS_API_KEY)
# No effect in .env: fixed in docker-compose.yml or left over from the upstream setup.
FIXED_KEYS=(
  NODE_ENV DATA_DIR WAKEUP_DRIVER AGENT_RUNTIME SANDBOX_PROVIDER SANDBOX_SUPERVISOR_URL
  CONTENT_ENCRYPTION MAX_UPLOAD_SIZE_MB API_HOST API_PORT POSTGRES_USER POSTGRES_DB
  POSTGRES_APP_PASSWORD RAKAZO_DATA_DIR RAKAZO_CREDENTIALS_DIR
  RAKAZO_IMAGE RAKAZO_COMPUTER_IMAGE RAKAZO_COMPUTER_IMAGE_TAG
  POSTGRES_IMAGE BUSYBOX_IMAGE CADDY_IMAGE CADDYFILE_PATH CADDY_HTTP_PORT CADDY_HTTPS_PORT
  RAKAZO_WEB_BIND DOCKER_SOCKET_PATH
)
SECRET_KEYS=(BETTER_AUTH_SECRET ENCRYPTION_KEY SCREEN_PROXY_SECRET SANDBOX_SUPERVISOR_TOKEN)

declare -A CUR=()  # values from the existing .env
declare -A NEW=()  # values to write
declare -A PF=()   # values from postfix/postfix.env
CUSTOM_LINES=()    # custom entries, copied unchanged
DROPPED_KEYS=()
DONE=()            # what this run wrote, for the summary
CADDY_TODO=()      # commands left to the user when the Caddy file was not written
CADDY_ROW=""       # Caddy line of the summary
RUN=()             # sudo when the current target needs it (see root_for)
PORTS_CHANGED=0
MODELS=""          # model IDs from the last fetch_models
MAIL_MODE=""       # receive, send, receive+send or empty
OLD_MAIL=""        # the same for the existing deployment
MAIL_DOMAIN=""     # domain of the mail addresses (after the @)
MAIL_PASSWORD=""   # its SMTP password
IPV4="" IPV6=""    # public addresses of this host, empty when unknown

die()  { printf '\nError: %s\n' "$*" >&2; exit 1; }
warn() { printf 'Warning: %s\n' "$*" >&2; }
is_in() { local x=$1 e; shift; for e; do [[ $e == "$x" ]] && return 0; done; return 1; }
trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
join() { local IFS=,; printf '%s' "$*"; }

load_env() {
  [[ -f $ENV_FILE ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
    key=${BASH_REMATCH[2]} val=${BASH_REMATCH[3]}
    if [[ $val =~ ^\'(.*)\'$ || $val =~ ^\"(.*)\"$ ]]; then
      val=${BASH_REMATCH[1]}
    else
      val=$(trim "${val%% #*}")
    fi
    CUR[$key]=$val
    if is_in "$key" "${FIXED_KEYS[@]}"; then
      DROPPED_KEYS+=("$key")
    elif ! is_in "$key" "${MANAGED_KEYS[@]}"; then
      CUSTOM_LINES+=("$line")
    fi
  done <"$ENV_FILE"
}

# postfix/postfix.env into PF, and the mail mode it holds while COMPOSE_PROFILES has mail into OLD_MAIL.
load_postfix_env() {
  local line
  if [[ -r postfix/postfix.env ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
      if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then PF[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}; fi
    done <postfix/postfix.env
  fi
  MAIL_DOMAIN=${PF[ALLOWED_SENDER_DOMAINS]:-}
  [[ ,${CUR[COMPOSE_PROFILES]:-}, == *,mail,* ]] || return 0
  [[ -z ${PF[POSTFIX_relay_domains]:-} ]] || OLD_MAIL=receive
  [[ -z ${PF[SMTPD_SASL_USERS]:-} ]] || OLD_MAIL+=${OLD_MAIL:++}send
}

as_root() { if ((EUID == 0)); then "$@"; else sudo "$@"; fi; }

# root_for FILE – RUN=() when this user may write FILE, otherwise asks once and sets RUN=(sudo).
# Returns 1 when the user declines.
root_for() {
  local dir=${1%/*}
  RUN=()
  ((EUID == 0)) && return 0
  [[ -w ${dir:-/} && (! -e $1 || -w $1) ]] && return 0
  ask_yn "$1 needs root. Write it with sudo" y || return 1
  RUN=(sudo)
}

# --- Input ---------------------------------------------------------------------------------------

# ask VAR "Question" [default] – Enter keeps the default, "-" clears the field.
ask() {
  local -n out=$1
  local reply
  read -r -p "$2${3:+ [$3]}: " reply || die "Input aborted."
  reply=$(trim "$reply")
  if [[ $reply == - ]]; then out=""; else out=${reply:-${3-}}; fi
}

# ask_secret VAR "Question" [current value] – no echo; Enter keeps, "-" removes.
ask_secret() {
  local -n out=$1
  local reply hint=""
  [[ -n ${3-} ]] && hint=" [set – Enter keeps, - removes]"
  read -r -s -p "$2$hint: " reply || die "Input aborted."
  printf '\n' >&2
  reply=$(trim "$reply")
  if [[ -z $reply ]]; then out=${3-}; elif [[ $reply == - ]]; then out=""; else out=$reply; fi
}

# ask_yn "Question" y|n – returns 0 for yes.
ask_yn() {
  local reply choices=y/N
  [[ $2 == y ]] && choices=Y/n
  while :; do
    read -r -p "$1 [$choices]: " reply || die "Input aborted."
    case ${reply:-$2} in
      [yY]*) return 0 ;;
      [nN]*) return 1 ;;
    esac
  done
}

# choose VAR default "Option 1" "Option 2" … – sets VAR to the chosen number.
choose() {
  local -n out=$1
  local def=$2 i reply
  shift 2
  for ((i = 1; i <= $#; i++)); do printf '  %d) %s\n' "$i" "${!i}" >&2; done
  while :; do
    read -r -p "Choice [$def]: " reply || die "Input aborted."
    reply=${reply:-$def}
    if [[ $reply =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= $#)); then out=$reply; return; fi
  done
}

normalize_host() {
  local h
  h=$(trim "${1,,}")
  h=${h#http://} h=${h#https://}
  h=${h%%/*}
  printf '%s' "${h%.}"
}

valid_host() {
  ((${#1} <= 253)) && [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

# Is something other than this stack listening on the port? No check without ss.
port_taken() {
  command -v ss >/dev/null || return 1
  [[ -n $(ss -Hltn "sport = :$1" 2>/dev/null) ]] || return 1
  [[ $(docker compose port "$2" "$3" 2>/dev/null) != *":$1" ]]
}

valid_ipv4() {
  local IFS=. o
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  for o in $1; do ((10#$o <= 255)) || return 1; done
}

# Address Caddy on this host uses to reach web and API: loopback unless they listen on one address.
upstream_ip() { if [[ $1 == 0.0.0.0 ]]; then printf 127.0.0.1; else printf '%s' "$1"; fi; }

valid_email() { [[ $1 =~ ^[^@[:space:]]+@[a-z0-9.-]+\.[a-z]{2,}$ ]]; }

# split_list "a, b c" → LIST=(a b c)
split_list() { read -r -a LIST <<<"${1//,/ }"; }

# Compose takes values in single quotes literally, including $ and spaces.
env_line() {
  local key=$1 val=${NEW[$1]-}
  [[ $val == *"'"* || $val == *$'\n'* ]] &&
    die "$key contains a ' or a line break. Please check the value."
  if [[ -z $val || $val =~ ^[A-Za-z0-9_.:/@,+=-]+$ ]]; then
    printf '%s=%s\n' "$key" "$val"
  else
    printf "%s='%s'\n" "$key" "$val"
  fi
}

# --- Deployment directory ------------------------------------------------------------------------

# Creates the deployment directory if needed, owned by the user running the script so that the
# script and docker compose (group docker) work there without sudo, and enters it.
enter_deploy_dir() {
  local group
  group=$(id -gn "$OWNER_USER")
  if [[ ! -d $DEPLOY_DIR ]] && ! { mkdir -p "${DEPLOY_DIR%/*}" && mkdir -m 750 "$DEPLOY_DIR"; } 2>/dev/null; then
    printf 'Creating %s needs root. It will belong to %s, so that this script and\n' "$DEPLOY_DIR" "$OWNER_USER"
    printf 'docker compose work there without sudo.\n'
    if ! ask_yn "Create it with sudo" y; then
      printf 'Create it yourself, then run the script again:\n  sudo install -d -o %s -g %s -m 750 %s\n' \
        "$OWNER_USER" "$group" "$DEPLOY_DIR"
      exit 1
    fi
    sudo install -d -o "$OWNER_USER" -g "$group" -m 750 "$DEPLOY_DIR" || die "Could not create $DEPLOY_DIR."
    DONE+=("$DEPLOY_DIR created, owned by $OWNER_USER")
  elif [[ ! -w $DEPLOY_DIR ]] && ((EUID != 0)); then
    printf '%s belongs to %s; this script and docker compose need it to belong to %s.\n' \
      "$DEPLOY_DIR" "$(stat -c %U "$DEPLOY_DIR")" "$OWNER_USER"
    if ! ask_yn "Hand it over with sudo chown" y; then
      printf 'Then:\n  sudo chown %s:%s %s\n' "$OWNER_USER" "$group" "$DEPLOY_DIR"
      exit 1
    fi
    sudo chown "$OWNER_USER:$group" "$DEPLOY_DIR" || die "Could not change the owner of $DEPLOY_DIR."
  fi
  if ((EUID == 0)) && [[ $OWNER_USER != root && $(stat -c %U "$DEPLOY_DIR") == root ]]; then
    chown "$OWNER_USER:$group" "$DEPLOY_DIR"
  fi
  cd "$DEPLOY_DIR"
}

# For --check, --owner and the account commands: enter the directory of an existing deployment.
use_deploy_dir() {
  if [[ ! -f $DEPLOY_DIR/$ENV_FILE ]]; then
    legacy_install &&
      die "This install still runs from the checkout. Run $SELF to move it to $DEPLOY_DIR, or add --dir $REPO_DIR."
    die "No .env in $DEPLOY_DIR. Run $SELF first."
  fi
  cd "$DEPLOY_DIR"
}

# The layout before /opt/rakazo: .env and data/ next to the script.
legacy_install() { [[ ! $REPO_DIR -ef $DEPLOY_DIR && (-f $REPO_DIR/$ENV_FILE || -d $REPO_DIR/data) ]]; }

# listing DIR ITEM… – path, type, size, owner and mode of everything below ITEM, sorted
listing() {
  local dir=$1
  shift
  (cd "$dir" && "${RUN[@]}" find "$@" \( -type d -printf '%p d %U:%G %m\n' \) -o -printf '%p %y %s %U:%G %m %l\n') |
    LC_ALL=C sort
}

# Moves .env, its backups, data/ and credentials/ of the old layout into the deployment directory:
# renamed on the same file system, otherwise copied with the originals kept as a backup.
migrate_legacy() {
  local items=() i same=1 before after keep="" moved=()
  if [[ -f $DEPLOY_DIR/$ENV_FILE ]]; then
    warn "$REPO_DIR still holds .env or data/ of the old layout; $DEPLOY_DIR is used."
    enter_deploy_dir
    return 0
  fi
  for i in "$REPO_DIR/$ENV_FILE" "$REPO_DIR/$ENV_FILE".bak.* "$REPO_DIR/data" "$REPO_DIR/credentials"; do
    if [[ -e $i ]]; then items+=("${i##*/}"); fi
  done
  section "Move the install to $DEPLOY_DIR"
  printf 'Rakazo now runs from %s instead of the checkout. Found in %s:\n' "$DEPLOY_DIR" "$REPO_DIR"
  printf '  %s\n' "${items[*]}"
  printf 'Moving them:\n'
  printf '  1. stops the stack: docker compose down in the checkout (data stays, computers keep running)\n'
  printf '  2. moves them to %s with owners and modes (postgres and app data belong to the\n' "$DEPLOY_DIR"
  printf '     container users, so this uses sudo)\n'
  printf '  3. compares owners, modes and sizes on both sides\n'
  if ! ask_yn "Move the install now" y; then
    printf 'Nothing changed. To keep running from the checkout: %s/generate-env.sh --dir %s\n' "$REPO_DIR" "$REPO_DIR"
    exit 0
  fi
  enter_deploy_dir
  for i in "${items[@]}"; do
    [[ ! -e $i ]] || die "$DEPLOY_DIR/$i already exists. Move it away first; nothing was changed."
    [[ $(stat -c %d "$REPO_DIR/$i") == $(stat -c %d .) ]] || same=0
  done
  RUN=()
  if ((EUID != 0)) && ! ask_yn "Use sudo for the move" y; then
    printf 'Nothing changed. By hand:\n  cd %s && docker compose down\n' "$REPO_DIR"
    if ((same)); then
      printf '  cd %s && sudo mv %s %s/\n' "$REPO_DIR" "${items[*]}" "$DEPLOY_DIR"
    else
      printf '  cd %s && sudo cp -a %s %s/\n' "$REPO_DIR" "${items[*]}" "$DEPLOY_DIR"
      printf '  then move the originals out of the checkout once Rakazo runs from %s\n' "$DEPLOY_DIR"
    fi
    printf 'and run %s again.\n' "$SELF"
    exit 1
  fi
  ((EUID == 0)) || RUN=(sudo)
  (cd "$REPO_DIR" && docker compose down) || die "Could not stop the stack in $REPO_DIR; nothing was moved."
  before=$(listing "$REPO_DIR" "${items[@]}") || die "Could not list ${items[*]} in $REPO_DIR; nothing was moved."
  for i in "${items[@]}"; do
    if ((same)); then
      "${RUN[@]}" mv -- "$REPO_DIR/$i" "$i" ||
        die "Moving $i failed. Already in $DEPLOY_DIR: ${moved[*]:-nothing}; the rest is still in $REPO_DIR."
    else
      "${RUN[@]}" cp -a -- "$REPO_DIR/$i" "$i" ||
        die "Copying $i failed. The originals in $REPO_DIR are unchanged; remove the partial copies in $DEPLOY_DIR."
    fi
    moved+=("$i")
  done
  after=$(listing . "${items[@]}")
  if [[ $before != "$after" ]]; then
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -20 >&2 || true
    if ((same)); then die "After the move the files differ from before (see above). Check $DEPLOY_DIR."; fi
    die "The copies differ from the originals (see above). The originals in $REPO_DIR are unchanged."
  fi
  if ((!same)); then
    keep=migrated-$STAMP
    mkdir "$REPO_DIR/$keep"
    for i in "${items[@]}"; do "${RUN[@]}" mv -- "$REPO_DIR/$i" "$REPO_DIR/$keep/"; done
  fi
  DONE+=("Moved ${items[*]} from $REPO_DIR (same files, owners, modes and sizes)")
  [[ -z $keep ]] || DONE+=("Originals kept in $REPO_DIR/$keep; delete them once Rakazo runs from $DEPLOY_DIR")
  deploy_file docker-compose.yml
  printf 'Moved and checked. The stack is stopped; to start it from the new place right away:\n'
  printf '  cd %s && docker compose up -d\n' "$DEPLOY_DIR"
  printf 'The settings below start from the moved .env and also update Caddy and the DNS list.\n'
}

# deploy_file PATH – copies PATH from the checkout; a copy that differs is backed up first. Sets
# COPIED to 0 (unchanged), 1 (new) or 2 (replaced).
deploy_file() {
  local f=$1
  COPIED=0
  if cmp -s "$REPO_DIR/$f" "$f"; then return 0; fi
  COPIED=1
  if [[ -f $f ]]; then cp -p "$f" "$f.bak.$STAMP"; COPIED=2; fi
  mkdir -p "$(dirname "$f")"
  cp "$REPO_DIR/$f" "$f.tmp.$$"
  mv -f "$f.tmp.$$" "$f"
}

deploy_files() {
  local f files=(docker-compose.yml) copied=() kept=""
  [[ $REPO_DIR -ef . ]] && return 0
  [[ -z $MAIL_MODE ]] || files+=(postfix/rakazo.sh postfix/rakazo-inbound-email)
  for f in "${files[@]}"; do
    deploy_file "$f"
    ((COPIED)) || continue
    ((COPIED == 1)) || kept=", previous versions kept as *.bak.$STAMP"
    copied+=("$f")
  done
  ((${#copied[@]} == 0)) || DONE+=("Copied from the checkout: $(join "${copied[@]}" | sed 's/,/, /g')$kept")
}

# A run as root leaves the files to the user the deployment directory belongs to.
hand_over() {
  local f group
  ((EUID == 0)) && [[ $OWNER_USER != root ]] || return 0
  group=$(id -gn "$OWNER_USER")
  for f in "$ENV_FILE" "$ENV_FILE".bak.* docker-compose* dns-records.txt ./*.new data credentials; do
    if [[ -e $f ]]; then chown "$OWNER_USER:$group" "$f"; fi
  done
  if [[ -d postfix ]]; then chown -R "$OWNER_USER:$group" postfix; fi
}

# --- Generate ------------------------------------------------------------------------------------

# Postgres data usually belongs to the container user; unreadable means in use.
pg_data_exists() {
  [[ -d data/postgres ]] || return 1
  [[ -r data/postgres && -x data/postgres ]] || return 0
  [[ -n $(ls -A data/postgres) ]]
}

# Networks Docker's configured address pools hold; empty while its built-in pools (about 30) apply.
pool_capacity() {
  local pools base size n=0
  pools=$(docker info --format '{{json .DefaultAddressPools}}' 2>/dev/null) || return 0
  while IFS=, read -r base size; do
    ((size >= ${base##*/})) && n=$((n + 2 ** (size - ${base##*/})))
  done < <(sed -n 's/"Base":"\([^"]*\)","Size":\([0-9]*\)/\n\1,\2\n/gp' <<<"$pools" | grep -E '^[0-9.]+/[0-9]+,[0-9]+$')
  ((n == 0)) || printf '%s' "$n"
}

# deployment_model CUR|NEW → "provider (model)" or "none (…)", as the API resolves it
deployment_model() {
  local -n m=$1
  local provider=${m[PI_DEFAULT_PROVIDER]:-openrouter} key
  case $provider in
    openrouter) key=${m[OPENROUTER_API_KEY]:-} ;;
    anthropic) key=${m[ANTHROPIC_API_KEY]:-} ;;
    deepseek) key=${m[DEEPSEEK_API_KEY]:-} ;;
    local)
      [[ ${m[PI_DEFAULT_CREDENTIALS]:-} == host && ,${m[RAKAZO_LOCAL_MODELS]:-}, == *,"${m[PI_DEFAULT_MODEL]:-}",* &&
        -n ${m[PI_DEFAULT_MODEL]:-} ]] && key=host || key=""
      ;;
    *) key=custom ;;
  esac
  if [[ -z $key ]]; then printf 'none (every account connects its own model)'
  else printf '%s (%s)' "$provider" "${m[PI_DEFAULT_MODEL]:-default model}"; fi
}

keep_or_new() { if [[ -n $1 ]]; then printf '%s' "$1"; else openssl rand -hex "$2"; fi; }

on_edge() { [[ ${NEW[RAKAZO_IMAGE_TAG]:-} == edge ]]; }

# edge_val KEY – the new value of an edge-only key, empty when the images are not edge
edge_val() { if on_edge; then printf '%s' "${NEW[$1]}"; fi; }

step_domain() {
  local domain old=${CUR[RAKAZO_HOST]:-}
  printf '\n== Domain ==\n'
  printf 'Caddy terminates TLS and forwards to web and API. All origins are derived from\n'
  printf 'this one domain so that sign-in, CORS and cookies match.\n'
  [[ $old == localhost ]] && old=""
  while :; do
    ask domain "Domain (e.g. rakazo.example.com)" "$old"
    domain=$(normalize_host "$domain")
    valid_host "$domain" && break
    warn "\"$domain\" is not a valid hostname (enter it without https://, path or port)."
  done
  if [[ -n $old && $old != "$domain" ]]; then
    warn "Domain changes from $old to $domain. Existing passkeys only work on the old domain,"
    warn "SSO redirect URIs and OAuth callbacks must be updated at the provider."
  fi

  NEW[RAKAZO_HOST]=$domain
  NEW[WEB_ORIGIN]=https://$domain
  NEW[BETTER_AUTH_URL]=https://$domain
  NEW[API_URL]=https://$domain
}

step_ports() {
  local web api mode def=1 bind proxy old_proxy old_web=${CUR[RAKAZO_WEB_PORT]:-} old_api=${CUR[RAKAZO_API_PORT]:-}
  local old_bind=${CUR[RAKAZO_BIND]:-${CUR[RAKAZO_WEB_BIND]:-127.0.0.1}}
  printf '\n== Ports ==\n'
  printf 'Where web and API listen. Caddy on this host reaches them on 127.0.0.1; any other address\n'
  printf 'serves them without TLS, and Docker publishes it past host firewalls such as ufw.\n'
  [[ $old_bind == 0.0.0.0 ]] && def=2
  [[ $old_bind == 127.0.0.1 || $old_bind == 0.0.0.0 ]] || def=3
  choose mode "$def" \
    "127.0.0.1 – only this host; Caddy here forwards to it (recommended)" \
    "0.0.0.0 – every network of this host, e.g. for a reverse proxy on another machine" \
    "one address of this host, e.g. its LAN or VPN IP for a reverse proxy on another machine"
  case $mode in
    1) bind=127.0.0.1 ;;
    2) bind=0.0.0.0 ;;
    3)
      [[ $old_bind == 127.0.0.1 || $old_bind == 0.0.0.0 ]] && old_bind=""
      while :; do
        ask bind "IPv4 address of this host" "$old_bind"
        valid_ipv4 "$bind" || { warn "\"$bind\" is not an IPv4 address."; continue; }
        if command -v ip >/dev/null && ! ip -4 -o addr show | grep -qF " $bind/"; then
          warn "This host has no address $bind; Docker cannot publish the ports there."
          ask_yn "Use it anyway" n || continue
        fi
        break
      done
      ;;
  esac
  NEW[RAKAZO_BIND]=$bind NEW[TRUSTED_PROXIES]=${CUR[TRUSTED_PROXIES]:-}
  # A proxy entry this script wrote goes with the remote proxy; hand-written values stay.
  [[ $bind != 127.0.0.1 || ${NEW[TRUSTED_PROXIES]} != local-networks,* ]] || NEW[TRUSTED_PROXIES]=""
  if [[ $bind != 127.0.0.1 ]]; then
    printf 'A reverse proxy on another machine reaches the API from its own address. The API believes\n'
    printf 'its X-Forwarded-For only if that address is trusted; otherwise every user shares one sign-in\n'
    printf 'rate limit.\n'
    old_proxy=${NEW[TRUSTED_PROXIES]#local-networks,}
    while :; do
      ask proxy "IP or CIDR of the reverse proxy (empty = Caddy runs on this host)" "$old_proxy"
      if [[ -z $proxy ]] || { [[ $proxy =~ ^[0-9.]+(/[0-9]{1,2})?$ ]] && valid_ipv4 "${proxy%/*}"; }; then break; fi
      warn "\"$proxy\" is not an IPv4 address or CIDR range."
    done
    NEW[TRUSTED_PROXIES]=${proxy:+local-networks,$proxy}
  fi
  while :; do
    ask web "Port for the web frontend" "${old_web:-$DEFAULT_WEB_PORT}"
    valid_port "$web" || { warn "\"$web\" is not a port (1–65535)."; continue; }
    if port_taken "$web" web 5173; then
      warn "Another service on this host already listens on port $web."
      ask_yn "Use it anyway" n || continue
    fi
    break
  done
  while :; do
    ask api "Port for the API" "${old_api:-$DEFAULT_API_PORT}"
    valid_port "$api" || { warn "\"$api\" is not a port (1–65535)."; continue; }
    ((10#$api != 10#$web)) || { warn "API and web need different ports."; continue; }
    if port_taken "$api" api 3100; then
      warn "Another service on this host already listens on port $api."
      ask_yn "Use it anyway" n || continue
    fi
    break
  done
  NEW[RAKAZO_WEB_PORT]=$((10#$web)) NEW[RAKAZO_API_PORT]=$((10#$api))
  if [[ -n $old_web$old_api && "$old_web:$old_api" != "${NEW[RAKAZO_WEB_PORT]}:${NEW[RAKAZO_API_PORT]}" ]]; then
    PORTS_CHANGED=1
  fi
}

step_images() {
  local mode def=1 old=${CUR[RAKAZO_IMAGE_TAG]:-}
  local opts=("latest – the newest release (recommended)" "edge – the current development state of main, untested")
  printf '\n== Release channel ==\n'
  printf 'edge gets every change first. Database migrations cannot be undone: going back from edge to\n'
  printf 'latest is only safe once a release has caught up with the edge you ran. Only edge offers so far:\n'
  printf 'SCIM provisioning, bot email addresses and --deactivate.\n'
  [[ $old == edge ]] && def=2
  if [[ -n $old && $old != latest && $old != edge ]]; then
    opts+=("keep $old")
    def=3
  fi
  choose mode "$def" "${opts[@]}"
  case $mode in 1) NEW[RAKAZO_IMAGE_TAG]=latest ;; 2) NEW[RAKAZO_IMAGE_TAG]=edge ;; 3) NEW[RAKAZO_IMAGE_TAG]=$old ;; esac
  if [[ $old == edge && ${NEW[RAKAZO_IMAGE_TAG]} == latest ]] && pg_data_exists; then
    warn "The database already has edge's migrations; latest may refuse to start until it catches up."
    ask_yn "Switch to latest anyway" n || NEW[RAKAZO_IMAGE_TAG]=edge
  fi
}

step_computers() {
  local def=y
  printf '\n== Computers ==\n'
  printf 'Every Private bot and every space gets a Docker container with a desktop and browser (up to\n'
  printf '2 GB RAM, 2 CPUs each); Team bots get their own screen in the space'"'"'s container.\n'
  printf 'By default Rakazo stops it after 10 minutes idle. For Docker the docs recommend keeping it\n'
  printf 'running so started apps and sessions stay open. That costs RAM, and every running computer\n'
  printf 'holds its own Docker network (the default address pools allow a few dozen).\n'
  [[ -v CUR[SANDBOX_IDLE_MS] && ${CUR[SANDBOX_IDLE_MS]} != 0 ]] && def=n
  NEW[SANDBOX_IDLE_MS]=0
  ask_yn "Keep computers running when idle" "$def" && return
  NEW[SANDBOX_IDLE_MS]=""
  if [[ ${CUR[SANDBOX_IDLE_MS]:-0} != 0 ]]; then NEW[SANDBOX_IDLE_MS]=${CUR[SANDBOX_IDLE_MS]}; fi
}

# remote_proxy CUR|NEW – does a reverse proxy on another machine replace Caddy on this host?
remote_proxy() {
  local -n rp=$1
  [[ ${rp[RAKAZO_BIND]:-127.0.0.1} != 127.0.0.1 && -n ${rp[TRUSTED_PROXIES]:-} ]]
}

# Is Caddy the packaged service, with its data in /var/lib/caddy/.local/share/caddy?
caddy_packaged() {
  [[ $(systemctl show -p User --value caddy 2>/dev/null) == caddy && $(getent passwd caddy | cut -d: -f6) == /var/lib/caddy ]]
}

step_mail() {
  local mode def=1 domain old_domain from host=${NEW[RAKAZO_HOST]} pw=${PF[SMTPD_SASL_USERS]:-}
  MAIL_MODE="" NEW[COMPOSE_PROFILES]=""
  printf '\n== Mail server (optional) ==\n'
  if remote_proxy NEW; then
    printf 'Postfix gets its certificate from Caddy on this host; with a reverse proxy on another\n'
    printf 'machine that is not available.\n'
    return 0
  elif ! caddy_packaged; then
    printf 'Postfix uses the certificate of Caddy from its Debian or RPM package (data in\n'
    printf '/var/lib/caddy/.local/share/caddy). Install that Caddy, then run this script again.\n'
    return 0
  fi
  printf 'Postfix in a container next to Rakazo, as mail server %s with Caddy'"'"'s certificate for\n' "$host"
  printf 'it. Addresses are name@<mail domain>: %s itself or a domain whose MX points to it.\n' "$host"
  if on_edge; then
    printf 'Receiving: Postfix takes mail for every name@<mail domain> and posts it to Rakazo, so bots get\n'
    printf 'email addresses. Sending: Rakazo has one way to send, so Postfix then carries all its mail,\n'
    printf 'account mail (verification, password resets, sign-in codes) included.\n'
  else
    printf 'Rakazo has one way to send, so Postfix then carries all its mail: verification, password\n'
    printf 'resets and sign-in codes.\n'
  fi
  printf 'Sending from this host needs outbound port 25 (many hosters block it until asked) and a PTR\n'
  printf 'record, and a new IP has no reputation yet; a relay such as Amazon SES (Email step) is safer.\n'
  if on_edge; then
    case $OLD_MAIL in receive) def=2 ;; *send) def=3 ;; esac
    choose mode "$def" "none" "receive bot email; sending stays with the Email step (Resend or any SMTP)" \
      "receive and send, account mail included"
    case $mode in 2) MAIL_MODE=receive ;; 3) MAIL_MODE=receive+send ;; esac
  else
    [[ $OLD_MAIL == *send ]] && def=2
    choose mode "$def" "none" "send Rakazo's mail, account mail included"
    ((mode == 1)) || MAIL_MODE=send
  fi
  [[ -n $MAIL_MODE ]] || return 0

  [[ $MAIL_MODE == send ]] ||
    printf 'Every name@<mail domain> goes to the bots: use a domain without mailboxes of its own.\n'
  old_domain=${PF[ALLOWED_SENDER_DOMAINS]:-${CUR[INBOUND_EMAIL_DOMAIN]:-$host}}
  [[ $old_domain != "${CUR[RAKAZO_HOST]:-}" ]] || old_domain=$host
  while :; do
    ask domain "Mail domain, the part after @" "$old_domain"
    domain=$(normalize_host "${domain#@}")
    valid_host "$domain" && break
    warn "\"$domain\" is not a valid domain name."
  done
  MAIL_DOMAIN=$domain NEW[COMPOSE_PROFILES]=mail
  MAIL_PASSWORD=$(keep_or_new "${pw#*:}" 32)
  if [[ $MAIL_MODE == receive* ]]; then
    NEW[INBOUND_EMAIL_DOMAIN]=$domain
    NEW[INBOUND_EMAIL_SECRET]=$(keep_or_new "${CUR[INBOUND_EMAIL_SECRET]:-}" 32)
  fi
  [[ $MAIL_MODE == *send ]] || return 0

  from=${CUR[EMAIL_FROM]:-}
  [[ $from == *"@$domain>"* || $from == *"@$domain" ]] || from="Rakazo <no-reply@$domain>"
  while :; do
    ask from "Sender" "$from"
    if [[ ! $from =~ [^@[:space:]\<]+@([^@[:space:]\>]+) ]]; then
      warn "The sender needs an email address, e.g. Rakazo <no-reply@$domain>."
    elif [[ ${BASH_REMATCH[1],,} != "$domain" ]]; then
      warn "Postfix sends as name@$domain only."
    else
      break
    fi
  done
  NEW[EMAIL_PROVIDER]=smtp NEW[EMAIL_API_KEY]="" NEW[EMAIL_FROM]=$from
  NEW[SMTP_URL]="smtp://rakazo%40$host:$MAIL_PASSWORD@postfix:587/?tls.servername=$host"
}

step_email() {
  local mode def=1 key from smtp old_smtp=${CUR[SMTP_URL]:-} old_provider=${CUR[EMAIL_PROVIDER]:-}
  # Set by step_mail: Postfix sends.
  [[ $MAIL_MODE != *send ]] || return 0
  # An SMTP_URL to the Postfix of this stack must not outlive it.
  [[ $old_smtp != smtp://rakazo*@postfix:587* ]] || old_smtp="" old_provider=""
  printf '\n== Email ==\n'
  printf 'For verification mails, password resets and sign-in codes. Without email there is no\n'
  printf 'password recovery, and an allowlist only works with SSO.\n'
  if [[ $MAIL_MODE == receive ]]; then
    printf 'Bots also send through it as name@%s: the provider must be allowed to send as\n' "$MAIL_DOMAIN"
    printf 'that domain.\n'
  fi
  if [[ $old_provider == resend ]]; then def=2
  elif [[ -n $old_smtp || $old_provider == smtp ]]; then def=3; fi
  choose mode "$def" "none" "Resend (HTTP API)" "SMTP (e.g. Amazon SES, Resend SMTP, your own server)"
  NEW[EMAIL_PROVIDER]="" NEW[EMAIL_API_KEY]="" NEW[SMTP_URL]="" NEW[EMAIL_FROM]=""
  ((mode == 1)) && return

  if ((mode == 2)); then
    while :; do
      ask_secret key "Resend API key (sending only, restricted to the domain)" "${CUR[EMAIL_API_KEY]:-}"
      [[ -n $key ]] && break
    done
    NEW[EMAIL_PROVIDER]=resend NEW[EMAIL_API_KEY]=$key
  else
    printf 'Format: smtps://user:password@host:465 (TLS) or smtp://…:587 (STARTTLS).\n'
    printf 'URL-encode special characters in user/password (@ → %%40, : → %%3A, / → %%2F).\n'
    while :; do
      ask_secret smtp "SMTP_URL" "$old_smtp"
      [[ $smtp =~ ^smtps?://[^[:space:]]+$ ]] && break
      warn "SMTP_URL must start with smtps:// or smtp://."
    done
    NEW[EMAIL_PROVIDER]=smtp NEW[SMTP_URL]=$smtp
  fi
  while :; do
    ask from "Sender (its domain must be verified at the provider)" \
      "${CUR[EMAIL_FROM]:-Rakazo <no-reply@${NEW[RAKAZO_HOST]}>}"
    [[ $from =~ [^@[:space:]\<]+@[^@[:space:]\>]+ ]] && break
    warn "The sender needs an email address, e.g. Rakazo <no-reply@example.com>."
  done
  NEW[EMAIL_FROM]=$from
}

step_bot_email() {
  local def=n domain
  # Set by step_mail: Postfix receives.
  [[ $MAIL_MODE != receive* ]] || return 0
  NEW[INBOUND_EMAIL_DOMAIN]=${CUR[INBOUND_EMAIL_DOMAIN]:-} NEW[INBOUND_EMAIL_SECRET]=${CUR[INBOUND_EMAIL_SECRET]:-}
  # Postfix of this stack was the relay: its domain does not outlive it.
  [[ $OLD_MAIL != receive* ]] || NEW[INBOUND_EMAIL_DOMAIN]="" NEW[INBOUND_EMAIL_SECRET]=""
  on_edge || return 0
  printf '\n== Bot email addresses (edge, optional) ==\n'
  printf 'Each bot can get name@<mail domain>: mail to it lands in its inbox (e.g. sign-up codes) and can\n'
  printf 'start routines. Needs a domain that receives mail for every name and a relay that posts each\n'
  printf 'message to Rakazo, here an outside one such as Cloudflare Email Routing (Postfix on this host is\n'
  printf 'the mail server step). Bots send through the email above; the provider must be allowed to send\n'
  printf 'as that domain.\n'
  [[ -n ${NEW[INBOUND_EMAIL_DOMAIN]} ]] && def=y
  if ! ask_yn "Give bots email addresses" "$def"; then
    NEW[INBOUND_EMAIL_DOMAIN]="" NEW[INBOUND_EMAIL_SECRET]=""
    return 0
  fi
  while :; do
    ask domain "Mail domain used for nothing else (e.g. agents.example.com)" "${NEW[INBOUND_EMAIL_DOMAIN]}"
    domain=$(normalize_host "${domain#@}")
    valid_host "$domain" && break
    warn "\"$domain\" is not a valid domain name."
  done
  NEW[INBOUND_EMAIL_DOMAIN]=$domain
  NEW[INBOUND_EMAIL_SECRET]=$(keep_or_new "${NEW[INBOUND_EMAIL_SECRET]}" 32)
}

step_signups() {
  local mode def list e entries=() first example=@company.com
  local closed="closed – nobody can sign up, not even with SSO; accounts only via --owner"
  [[ -z $(edge_val SCIM_BEARER_TOKEN) ]] || closed+=" and SCIM"
  printf '\n== Signup ==\n'
  printf 'Who may create an account on their own. There is no "closed except one domain": to admit only\n'
  printf '@company.com, signup stays on with an allowlist. Admin accounts are created with a password\n'
  printf 'via ./generate-env.sh --owner in every mode.\n'
  if [[ ${CUR[SIGNUPS_ENABLED]:-} == false ]]; then def=1
  elif [[ -n ${CUR[SIGNUP_ALLOWLIST]:-} ]]; then def=2
  elif [[ ${CUR[SIGNUPS_ENABLED]:-} == true ]]; then def=3
  elif [[ -n ${NEW[EMAIL_PROVIDER]}${NEW[OIDC_ISSUER]} ]]; then def=2
  else def=1; fi
  while :; do
    choose mode "$def" \
      "$closed" \
      "allowlist – only listed addresses or domains, via SSO or verification mail (needs one of them)" \
      "open – anyone who reaches the domain can create an account"
    if ((mode == 2)) && [[ -z ${NEW[EMAIL_PROVIDER]}${NEW[OIDC_ISSUER]} ]]; then
      warn "An allowlist needs email delivery or SSO. Without either nobody can sign up."
      def=1
      continue
    fi
    if ((mode == 2)) && [[ -n ${NEW[OIDC_ALLOW_SIGNUP_BYPASS]} ]]; then
      printf 'SSO sign-up skips the allowlist (provider without email_verified). It still limits password\n'
      printf 'sign-up, which also needs email.\n'
    elif ((mode == 2)) && [[ -z ${NEW[EMAIL_PROVIDER]} ]]; then
      printf 'Without email only SSO sign-up works; the provider must send email_verified=true.\n'
    fi
    if ((mode == 1)) && [[ -n ${NEW[OIDC_ALLOW_SIGNUP_BYPASS]} ]]; then
      warn "Closed signup with a provider without email_verified: SSO cannot be used at all."
      ask_yn "Keep signup closed anyway" n || { def=2; continue; }
    fi
    if ((mode == 3)) && ! ask_yn "Really open? Anyone with access to https://${NEW[RAKAZO_HOST]} can create an account" n; then
      continue
    fi
    break
  done

  NEW[SIGNUPS_ENABLED]=true NEW[SIGNUP_ALLOWLIST]=""
  case $mode in
    1) NEW[SIGNUPS_ENABLED]=false ;;
    2)
      first=${NEW[RAKAZO_ADMIN_EMAILS]%%,*}
      [[ -n $first ]] && example=@${first#*@}
      while :; do
        ask list "Allowed addresses or domains, comma-separated (e.g. $example)" "${CUR[SIGNUP_ALLOWLIST]:-}"
        split_list "$list"
        entries=()
        for e in "${LIST[@]}"; do
          e=${e,,}
          if valid_email "$e" || [[ $e =~ ^@[a-z0-9.-]+\.[a-z]{2,}$ ]]; then entries+=("$e")
          else warn "\"$e\" is neither an email address nor @domain."; continue 2; fi
        done
        ((${#entries[@]})) && break
      done
      NEW[SIGNUP_ALLOWLIST]=$(join "${entries[@]}")
      ;;
  esac
  SIGNUP_MODE=$mode
}

step_admins() {
  local list e entries
  printf '\n== Admin accounts ==\n'
  printf 'May review plugin submissions and add stdio MCP servers; no other special rights. After the\n'
  printf 'start create the account with a password: ./generate-env.sh --owner (first address is the default).\n'
  while :; do
    ask list "Admin emails, comma-separated (empty = none)" "${CUR[RAKAZO_ADMIN_EMAILS]:-}"
    split_list "$list"
    entries=()
    for e in "${LIST[@]}"; do
      e=${e,,}
      valid_email "$e" || { warn "\"$e\" is not an email address."; continue 2; }
      entries+=("$e")
    done
    break
  done
  NEW[RAKAZO_ADMIN_EMAILS]=$(join "${entries[@]}")
}

is_entra() { [[ $1 == https://login.microsoftonline.com/* ]]; }
valid_entra_issuer() { [[ $1 =~ ^https://login\.microsoftonline\.com/[0-9a-fA-F-]{36}/v2\.0$ ]]; }

step_sso() {
  local def=n issuer id secret name
  printf '\n== SSO via OpenID Connect (optional) ==\n'
  NEW[OIDC_ISSUER]="" NEW[OIDC_CLIENT_ID]="" NEW[OIDC_CLIENT_SECRET]="" NEW[OIDC_NAME]=""
  NEW[OIDC_ALLOW_SIGNUP_BYPASS]=""
  [[ -n ${CUR[OIDC_ISSUER]:-} ]] && def=y
  ask_yn "Set up SSO" "$def" || return 0
  printf 'Redirect URI to register at the provider: https://%s/api/auth/callback/oidc\n' "${NEW[RAKAZO_HOST]}"
  printf 'The ID token needs the email claim (Entra ID: Token configuration → optional claim email).\n'
  while :; do
    ask issuer "Issuer URL (exactly as in the discovery document)" "${CUR[OIDC_ISSUER]:-}"
    if [[ ! $issuer =~ ^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$ ]]; then
      warn "The issuer must be an https URL without query or fragment."
    elif is_entra "$issuer" && ! valid_entra_issuer "$issuer"; then
      warn "For Entra ID use https://login.microsoftonline.com/<tenant ID>/v2.0 (the GUID, no common)."
    else
      break
    fi
  done
  while :; do ask id "Client ID" "${CUR[OIDC_CLIENT_ID]:-}"; [[ -n $id ]] && break; done
  while :; do ask_secret secret "Client secret" "${CUR[OIDC_CLIENT_SECRET]:-}"; [[ -n $secret ]] && break; done
  ask name "Sign-in button label" "${CUR[OIDC_NAME]:-SSO}"
  NEW[OIDC_ISSUER]=$issuer NEW[OIDC_CLIENT_ID]=$id NEW[OIDC_CLIENT_SECRET]=$secret NEW[OIDC_NAME]=$name

  printf 'Rakazo trusts the SSO email only with email_verified=true in the ID token. Microsoft Entra ID\n'
  printf 'never sends it; verified_primary_email and xms_edov are not read.\n'
  def=y
  [[ ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} == true ]] || is_entra "$issuer" && def=n
  if ! ask_yn "Does the provider send email_verified=true" "$def"; then
    NEW[OIDC_ALLOW_SIGNUP_BYPASS]=true
    printf 'SSO sign-up then skips the allowlist: everyone the provider lets in can create an account.\n'
    printf 'Restrict it there (Entra ID: Enterprise application → Properties → Assignment required).\n'
    printf 'SSO accounts stay unverified: no admin rights and no Link SSO. Admins use --owner.\n'
  fi
}

step_directory() {
  local def=n
  NEW[SCIM_BEARER_TOKEN]=${CUR[SCIM_BEARER_TOKEN]:-}
  on_edge || return 0
  printf '\n== Directory provisioning via SCIM (edge, optional) ==\n'
  printf 'Your identity provider creates and locks accounts, also while signup is closed: then exactly\n'
  printf 'the people assigned there get in, and removing someone ends all their sessions at once. A new\n'
  printf 'account takes over its SSO login only with email_verified=true, otherwise it signs in with a\n'
  printf 'code by email.\n'
  [[ -n ${NEW[SCIM_BEARER_TOKEN]} ]] && def=y
  if ! ask_yn "Set up SCIM" "$def"; then
    NEW[SCIM_BEARER_TOKEN]=""
    return 0
  fi
  if [[ -z ${NEW[EMAIL_PROVIDER]} && (-z ${NEW[OIDC_ISSUER]} || -n ${NEW[OIDC_ALLOW_SIGNUP_BYPASS]}) ]]; then
    warn "No email delivery and no SSO with email_verified: accounts from SCIM could not sign in."
    ask_yn "Set up SCIM anyway" n || { NEW[SCIM_BEARER_TOKEN]=""; return 0; }
  elif [[ -n ${NEW[OIDC_ALLOW_SIGNUP_BYPASS]} ]]; then
    printf 'Your provider sends no email_verified: accounts from SCIM sign in with a code by email, not SSO.\n'
  fi
  NEW[SCIM_BEARER_TOKEN]=$(keep_or_new "${NEW[SCIM_BEARER_TOKEN]}" 32)
  printf 'At the provider: SCIM base URL https://%s/api/auth/scim/v2, token = SCIM_BEARER_TOKEN in .env.\n' \
    "${NEW[RAKAZO_HOST]}"
}

step_catalog() {
  local mode def=1 key id secret project pd_env
  printf '\n== App catalog (optional) ==\n'
  printf 'Gmail, Slack, Notion, GitHub & co. under Integrations → Apps need a connector service on a\n'
  printf 'self-hosted instance. Your own MCP servers, OpenAPI and GraphQL work without one.\n'
  [[ -n ${CUR[COMPOSIO_API_KEY]:-} ]] && def=2
  [[ -n ${CUR[PIPEDREAM_CLIENT_ID]:-} ]] && def=3
  choose mode "$def" "none" "Composio" "Pipedream Connect"
  NEW[COMPOSIO_API_KEY]="" NEW[PIPEDREAM_CLIENT_ID]="" NEW[PIPEDREAM_CLIENT_SECRET]=""
  NEW[PIPEDREAM_PROJECT_ID]="" NEW[PIPEDREAM_ENVIRONMENT]=""
  case $mode in
    2)
      while :; do ask_secret key "Composio API key" "${CUR[COMPOSIO_API_KEY]:-}"; [[ -n $key ]] && break; done
      NEW[COMPOSIO_API_KEY]=$key
      ;;
    3)
      while :; do ask id "Pipedream client ID" "${CUR[PIPEDREAM_CLIENT_ID]:-}"; [[ -n $id ]] && break; done
      while :; do ask_secret secret "Pipedream client secret" "${CUR[PIPEDREAM_CLIENT_SECRET]:-}"; [[ -n $secret ]] && break; done
      while :; do ask project "Pipedream project ID" "${CUR[PIPEDREAM_PROJECT_ID]:-}"; [[ -n $project ]] && break; done
      printf 'Anything other than "production" uses Pipedream'"'"'s development environment.\n'
      while :; do
        ask pd_env "Pipedream environment (production/development)" "${CUR[PIPEDREAM_ENVIRONMENT]:-production}"
        [[ $pd_env == production || $pd_env == development ]] && break
      done
      NEW[PIPEDREAM_CLIENT_ID]=$id NEW[PIPEDREAM_CLIENT_SECRET]=$secret
      NEW[PIPEDREAM_PROJECT_ID]=$project NEW[PIPEDREAM_ENVIRONMENT]=$pd_env
      ;;
  esac
  CATALOG_MODE=$mode
}

# api_get URL HEADER… – body of a GET request. Status 0 = 200, 1 = key rejected (401/403), 2 = no
# usable answer. The headers go through a file descriptor, so keys stay out of the process list.
api_get() {
  local url=$1 res
  shift
  command -v curl >/dev/null || return 2
  res=$(curl -sS --max-time 20 -w '\n%{http_code}' -H @<(printf '%s\n' "$@") "$url" 2>/dev/null) || return 2
  case ${res##*$'\n'} in
    200) printf '%s' "${res%$'\n'*}" ;;
    401 | 403) return 1 ;;
    *) return 2 ;;
  esac
}

# fetch_models PROVIDER KEY – sets MODELS to the model IDs the provider lists, one per line. For
# local: fetch_models local BASE_URL [KEY]. Status as api_get.
fetch_models() {
  local body
  MODELS=""
  case $1 in
    openrouter)
      api_get https://openrouter.ai/api/v1/key "Authorization: Bearer $2" >/dev/null || return
      body=$(api_get https://openrouter.ai/api/v1/models 'Accept: application/json') || return 2
      ;;
    anthropic)
      body=$(api_get 'https://api.anthropic.com/v1/models?limit=1000' "x-api-key: $2" \
        'anthropic-version: 2023-06-01') || return
      ;;
    deepseek) body=$(api_get https://api.deepseek.com/models "Authorization: Bearer $2") || return ;;
    local) body=$(api_get "${2%/}/models" "Authorization: Bearer ${3:-local}") || return ;;
  esac
  MODELS=$(grep -o '"id" *: *"[^"]*"' <<<"$body" | sed 's/.*"\([^"]*\)"$/\1/' || true)
  [[ -n $MODELS ]] || return 2
}

has_model() { grep -qxF -- "$1" <<<"$MODELS"; }

# Lines from stdin as a,b,c.
csv() { local s; s=$(tr '\n' ,); printf '%s' "${s%,}"; }

# similar_models ID – " Similar: …" with up to five listed IDs that resemble ID
similar_models() {
  local s name=${1##*/}
  s=$({ grep -iF -- "$name" <<<"$MODELS" || grep -iF -- "${name%%[-:.]*}" <<<"$MODELS"; } | head -5 | csv || true)
  [[ -z $s ]] || printf ' Similar: %s' "${s//,/, }"
}

step_models() {
  local mode def=1 provider label var dm key model k st old_provider=${CUR[PI_DEFAULT_PROVIDER]:-openrouter}
  local opts=("none – every account connects its own model" "OpenRouter" "Anthropic" "DeepSeek"
    "OpenAI-compatible server (vLLM, Ollama, LM Studio, llama.cpp, LiteLLM …)")
  printf '\n== Deployment model ==\n'
  printf 'Used by every account that has not connected a model of its own; all usage is billed to\n'
  printf 'this key. Without it every new account, SSO included, has to connect its own model provider\n'
  printf 'before the first chat. Pick a vision-capable model so the screen tools stay available.\n'
  case $old_provider in
    openrouter) [[ -n ${CUR[OPENROUTER_API_KEY]:-} ]] && def=2 ;;
    anthropic) [[ -n ${CUR[ANTHROPIC_API_KEY]:-} ]] && def=3 ;;
    deepseek) [[ -n ${CUR[DEEPSEEK_API_KEY]:-} ]] && def=4 ;;
    local) def=5 ;;
    *) opts+=("keep $old_provider (set by hand)"); def=6 ;;
  esac
  choose mode "$def" "${opts[@]}"
  for k in PI_DEFAULT_PROVIDER PI_DEFAULT_MODEL PI_DEFAULT_CREDENTIALS OPENROUTER_API_KEY ANTHROPIC_API_KEY \
    DEEPSEEK_API_KEY RAKAZO_LOCAL_MODELS_URL RAKAZO_LOCAL_MODELS_API_KEY RAKAZO_LOCAL_MODELS \
    RAKAZO_LOCAL_VISION_MODELS RAKAZO_LOCAL_CONTEXT_WINDOW RAKAZO_LOCAL_MAX_TOKENS; do
    NEW[$k]=${CUR[$k]:-}
  done
  ((mode == 6)) && return 0
  NEW[PI_DEFAULT_PROVIDER]="" NEW[PI_DEFAULT_MODEL]="" NEW[PI_DEFAULT_CREDENTIALS]=""
  case $mode in
    2)
      provider=openrouter label=OpenRouter var=OPENROUTER_API_KEY dm=openai/gpt-6-luna
      on_edge && dm=anthropic/claude-haiku-5.5
      ;;
    3) provider=anthropic label=Anthropic var=ANTHROPIC_API_KEY dm=claude-sonnet-5 ;;
    4) provider=deepseek label=DeepSeek var=DEEPSEEK_API_KEY dm=deepseek-flash ;;
    5) step_local_model; return 0 ;;
    *)
      # An OpenRouter key alone already makes OpenRouter the deployment model.
      NEW[OPENROUTER_API_KEY]=""
      return 0
      ;;
  esac
  while :; do
    ask_secret key "$label API key" "${CUR[$var]:-}"
    [[ -n $key ]] || continue
    st=0
    fetch_models "$provider" "$key" || st=$?
    case $st in
      0) printf 'Key works; %s lists %d models.\n' "$label" "$(wc -l <<<"$MODELS")"; break ;;
      1) warn "$label rejects this key." && ask_yn "Use it anyway" n && break ;;
      *) printf 'Could not ask %s for its models (offline or no curl): key and model stay unchecked.\n' "$label"; break ;;
    esac
  done
  ((${#MODELS} == 0 || $(wc -l <<<"$MODELS") > 15)) || printf 'Available: %s\n' "$(csv <<<"$MODELS" | sed 's/,/, /g')"
  [[ -z $MODELS ]] || has_model "$dm" || printf 'Rakazo'"'"'s default %s is not listed: enter a model.\n' "$dm"
  [[ $provider == "$old_provider" ]] && model=${CUR[PI_DEFAULT_MODEL]:-} || model=""
  while :; do
    ask model "Model (empty = Rakazo default, currently $dm)" "$model"
    [[ -z $MODELS ]] || has_model "${model:-$dm}" && break
    warn "$label does not list \"${model:-$dm}\".$(similar_models "${model:-$dm}")"
    ask_yn "Use it anyway" n && break
  done
  NEW[$var]=$key NEW[PI_DEFAULT_MODEL]=$model
  [[ $provider == openrouter ]] || NEW[PI_DEFAULT_PROVIDER]=$provider
}

step_local_model() {
  local url key ids suggest="" vision model ctx max e st st_local
  printf 'API and worker must reach the server: an https URL, a LAN IP, or\n'
  printf 'http://host.docker.internal:<port>/v1 for a server on this host that listens on more than 127.0.0.1.\n'
  while :; do
    ask url "Base URL (e.g. https://llm.example.com/v1)" "${CUR[RAKAZO_LOCAL_MODELS_URL]:-}"
    [[ $url =~ ^https?://[^/?#[:space:]]+(/[^?#[:space:]]*)?$ ]] && break
    warn "The base URL must be an http(s) URL without query or fragment."
  done
  on_edge || printf 'Only edge or a release after v0.8.0 sends a server key; older images send the key "local".\n'
  while :; do
    ask_secret key "Server API key (empty = none)" "${CUR[RAKAZO_LOCAL_MODELS_API_KEY]:-}"
    st=0
    fetch_models local "$url" "$key" || st=$?
    case $st in
      0) printf 'The server lists %d models: %s\n' "$(wc -l <<<"$MODELS")" "$(csv <<<"$MODELS" | sed 's/,/, /g')"; break ;;
      1) warn "The server rejects ${key:+this key}${key:-requests without a key}." && ask_yn "Use it anyway" n && break ;;
      *) printf 'Not reachable from this host, which is fine if only containers reach it (host.docker.internal);\n'
         printf './generate-env.sh --check tests it from the api container once the stack runs.\n'
         break ;;
    esac
  done
  if [[ -n $key && $st == 0 ]] && ! on_edge; then
    st_local=0
    api_get "${url%/}/models" 'Authorization: Bearer local' >/dev/null || st_local=$?
    if ((st_local == 1)); then
      warn "The server rejects the key \"local\" that ${NEW[RAKAZO_IMAGE_TAG]} sends: runs fail with 401."
      warn "Choose edge, connect it per account (Settings → Models → OpenAI-compatible) or pick another provider."
    fi
  fi
  if (($(wc -l <<<"$MODELS") <= 15)); then suggest=$(csv <<<"$MODELS"); fi
  while :; do
    ask ids "Model IDs to offer, comma-separated" "${CUR[RAKAZO_LOCAL_MODELS]:-$suggest}"
    split_list "$ids"
    ((${#LIST[@]})) || continue
    [[ -z $MODELS ]] && break
    for e in "${LIST[@]}"; do has_model "$e" || warn "The server does not list \"$e\".$(similar_models "$e")"; done
    for e in "${LIST[@]}"; do has_model "$e" || { ask_yn "Use the list anyway" n && break 2; continue 2; }; done
    break
  done
  ids=$(join "${LIST[@]}")
  [[ ,$ids, == *,"${CUR[PI_DEFAULT_MODEL]:-}",* ]] && model=${CUR[PI_DEFAULT_MODEL]} || model=${LIST[0]}
  while :; do
    ask model "Deployment model (one of $ids)" "$model"
    [[ ,$ids, == *,"$model",* ]] && break
    warn "\"$model\" is not in the list."
  done
  ask vision "Models that accept images, comma-separated (empty = none)" "${CUR[RAKAZO_LOCAL_VISION_MODELS]:-}"
  split_list "$vision"
  vision=$(join "${LIST[@]}")
  [[ ,$vision, == *,"$model",* ]] ||
    warn "$model is not marked as accepting images: the screen tools of the computers are unavailable."
  for e in ctx max; do
    while :; do
      if [[ $e == ctx ]]; then ask ctx "Context window in tokens" "${CUR[RAKAZO_LOCAL_CONTEXT_WINDOW]:-32768}"
      else ask max "Max output tokens per request" "${CUR[RAKAZO_LOCAL_MAX_TOKENS]:-4096}"; fi
      [[ ${!e} =~ ^[1-9][0-9]*$ ]] && break
      warn "Enter a positive whole number."
    done
  done
  NEW[RAKAZO_LOCAL_MODELS_URL]=$url NEW[RAKAZO_LOCAL_MODELS_API_KEY]=$key
  NEW[RAKAZO_LOCAL_MODELS]=$ids NEW[RAKAZO_LOCAL_VISION_MODELS]=$vision
  NEW[RAKAZO_LOCAL_CONTEXT_WINDOW]=$ctx NEW[RAKAZO_LOCAL_MAX_TOKENS]=$max
  NEW[PI_DEFAULT_PROVIDER]=local NEW[PI_DEFAULT_MODEL]=$model NEW[PI_DEFAULT_CREDENTIALS]=host
}

step_secrets() {
  local app_pw=${CUR[POSTGRES_APP_PASSWORD]:-} k
  if [[ -z $app_pw && ${CUR[DATABASE_URL]:-} =~ ^postgres://rakazo_app:([^@]+)@ ]]; then
    app_pw=${BASH_REMATCH[1]}
  fi
  NEW[POSTGRES_PASSWORD]=$(keep_or_new "${CUR[POSTGRES_PASSWORD]:-}" 16)
  app_pw=$(keep_or_new "$app_pw" 16)
  [[ ${NEW[POSTGRES_PASSWORD]} =~ ^[A-Za-z0-9._~-]+$ && $app_pw =~ ^[A-Za-z0-9._~-]+$ ]] ||
    die "A Postgres password contains characters that are not allowed in the connection URL (@ : / ? # % …)."
  NEW[DATABASE_URL]=postgres://rakazo_app:$app_pw@postgres:5432/rakazo
  NEW[DATABASE_MIGRATION_URL]=postgres://rakazo:${NEW[POSTGRES_PASSWORD]}@postgres:5432/rakazo
  for k in "${SECRET_KEYS[@]}"; do NEW[$k]=$(keep_or_new "${CUR[$k]:-}" 32); done
}

write_env() {
  local tmp backup="" line
  tmp=$(mktemp "$ENV_FILE.XXXXXX")
  {
    printf '# Rakazo – written by generate-env.sh on %s. Contains secrets: do not commit or share.\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '# To change: run %s/generate-env.sh again. Then here: docker compose up -d\n' "$REPO_DIR"
    cat <<'EOF'

# --- Access ---------------------------------------------------------------------------------------
# The three origins are exactly https://<RAKAZO_HOST>, without a trailing slash. If one differs you
# get 403 INVALID_ORIGIN, CORS errors or cookies that never arrive. vite needs RAKAZO_HOST for its
# host check (otherwise 403 and a blank computer screen).
EOF
    env_line RAKAZO_HOST
    env_line WEB_ORIGIN
    env_line BETTER_AUTH_URL
    env_line API_URL
    cat <<'EOF'

# --- Ports ----------------------------------------------------------------------------------------
# RAKAZO_BIND: 127.0.0.1 = only this host, where Caddy forwards to them. 0.0.0.0 or a host IP
# serves web and API without TLS and past ufw. Change them with generate-env.sh, which also updates
# the Caddy file, then docker compose up -d. TRUSTED_PROXIES lists a reverse proxy on another
# machine, so the API believes its X-Forwarded-For.
EOF
    env_line RAKAZO_BIND
    env_line RAKAZO_WEB_PORT
    env_line RAKAZO_API_PORT
    env_line TRUSTED_PROXIES
    cat <<'EOF'

# --- Images ---------------------------------------------------------------------------------------
# latest = newest release, edge = development state of main. Apply a change or an update with
EOF
    printf '# docker compose pull && docker compose up -d\n'
    env_line RAKAZO_IMAGE_TAG
    cat <<'EOF'

# --- Computers ------------------------------------------------------------------------------------
# 0 = computers keep running when idle. Empty = Rakazo stops them after 10 minutes idle.
EOF
    env_line SANDBOX_IDLE_MS
    cat <<'EOF'

# --- Database -------------------------------------------------------------------------------------
# POSTGRES_PASSWORD only applies on the first start with an empty ./data/postgres; do not change it
# afterwards. DATABASE_MIGRATION_URL (owner login for migrate) contains the same password. migrate
# sets the password of the app login rakazo_app in DATABASE_URL on every start.
EOF
    env_line POSTGRES_PASSWORD
    env_line DATABASE_URL
    env_line DATABASE_MIGRATION_URL
    cat <<'EOF'

# --- Secrets --------------------------------------------------------------------------------------
# Independent random values. Never change ENCRYPTION_KEY: stored credentials and content would
# become unreadable. A new BETTER_AUTH_SECRET signs everyone out.
EOF
    env_line BETTER_AUTH_SECRET
    env_line ENCRYPTION_KEY
    env_line SCREEN_PROXY_SECRET
    env_line SANDBOX_SUPERVISOR_TOKEN
    cat <<'EOF'

# --- Accounts -------------------------------------------------------------------------------------
# SIGNUPS_ENABLED=false: nobody can sign up, not even with SSO; create accounts with
# ./generate-env.sh --owner. To admit only some addresses or domains keep signup on and set
# SIGNUP_ALLOWLIST (you@example.com,@company.com); that needs email delivery or SSO.
EOF
    env_line SIGNUPS_ENABLED
    env_line SIGNUP_ALLOWLIST
    env_line RAKAZO_ADMIN_EMAILS
    printf '# Edge only: SCIM token for the identity provider, base URL https://%s/api/auth/scim/v2\n' \
      "${NEW[RAKAZO_HOST]}"
    env_line SCIM_BEARER_TOKEN
    printf '\n# --- Email (optional) ----------------------------------------------------------------------------\n'
    if [[ $MAIL_MODE == *send ]]; then
      printf '# SMTP_URL points to Postfix in this stack (mail server below); generate-env.sh sets it.\n'
    fi
    env_line EMAIL_PROVIDER
    env_line EMAIL_API_KEY
    env_line SMTP_URL
    env_line EMAIL_FROM
    printf '\n# --- Bot email addresses (edge, optional) ---------------------------------------------------------\n'
    printf '# The relay posts each message to https://%s/api/v1/email/inbound?to=<recipient>\n' "${NEW[RAKAZO_HOST]}"
    printf '# with Authorization: Bearer <INBOUND_EMAIL_SECRET>; see docs/self-host-inbound-email.md.\n'
    if [[ $MAIL_MODE == receive* ]]; then
      printf '# Postfix in this stack is that relay (mail server below); generate-env.sh sets both.\n'
    fi
    env_line INBOUND_EMAIL_DOMAIN
    env_line INBOUND_EMAIL_SECRET
    cat <<'EOF'

# --- Mail server (optional) -----------------------------------------------------------------------
# mail = Postfix runs (settings and DKIM key in postfix/, written by generate-env.sh); empty = off.
EOF
    env_line COMPOSE_PROFILES
    printf '\n# --- SSO (optional) ------------------------------------------------------------------------------\n'
    printf '# Redirect URI at the provider: https://%s/api/auth/callback/oidc\n' "${NEW[RAKAZO_HOST]}"
    env_line OIDC_ISSUER
    env_line OIDC_CLIENT_ID
    env_line OIDC_CLIENT_SECRET
    env_line OIDC_NAME
    printf '# true for providers without email_verified (Entra ID); SSO sign-up then skips the allowlist.\n'
    env_line OIDC_ALLOW_SIGNUP_BYPASS
    printf '\n# --- App catalog (optional) -----------------------------------------------------------------------\n'
    printf '# Integrations → Apps: Composio or Pipedream Connect. Without either there is no catalog.\n'
    env_line COMPOSIO_API_KEY
    env_line PIPEDREAM_CLIENT_ID
    env_line PIPEDREAM_CLIENT_SECRET
    env_line PIPEDREAM_PROJECT_ID
    env_line PIPEDREAM_ENVIRONMENT
    printf '\n# --- Deployment model -----------------------------------------------------------------------------\n'
    printf '# Used by every account without a model of its own. PI_DEFAULT_PROVIDER empty = openrouter;\n'
    printf '# PI_DEFAULT_MODEL empty = the provider default. Without the key of that provider every new\n'
    printf '# account has to connect its own model.\n'
    env_line PI_DEFAULT_PROVIDER
    env_line PI_DEFAULT_MODEL
    env_line PI_DEFAULT_CREDENTIALS
    env_line OPENROUTER_API_KEY
    env_line ANTHROPIC_API_KEY
    env_line DEEPSEEK_API_KEY
    printf '# OpenAI-compatible server: PI_DEFAULT_PROVIDER=local, PI_DEFAULT_CREDENTIALS=host and these.\n'
    env_line RAKAZO_LOCAL_MODELS_URL
    printf '# Bearer key of that server (edge or a release after v0.8.0; older images send the key "local").\n'
    env_line RAKAZO_LOCAL_MODELS_API_KEY
    env_line RAKAZO_LOCAL_MODELS
    env_line RAKAZO_LOCAL_VISION_MODELS
    env_line RAKAZO_LOCAL_CONTEXT_WINDOW
    env_line RAKAZO_LOCAL_MAX_TOKENS
    cat <<'EOF'

# --- Custom entries -------------------------------------------------------------------------------
# Every service reads the whole .env: keys added here (more provider keys, object storage,
# Infisical, HTTP_PROXY, Sentry, messaging, CSP, SANDBOX_COMPUTER_MOUNTS …) reach the containers
# without changing the Compose file. Values under environment in docker-compose.yml take precedence.
# Reference: docs/self-host-*.md in the Rakazo repo. Quote values with $ or spaces in '…'.
# generate-env.sh keeps this section unchanged on every run.
EOF
    for line in "${CUSTOM_LINES[@]}"; do printf '%s\n' "$line"; done
  } >"$tmp"
  chmod 600 "$tmp"
  if [[ -f $ENV_FILE ]]; then
    backup=$ENV_FILE.bak.$STAMP
    cp -p "$ENV_FILE" "$backup"
    chmod 600 "$backup"
  fi
  mv "$tmp" "$ENV_FILE"
  DONE+=(".env written (mode 600)${backup:+, previous file backed up as $backup}")
}

# postfix/postfix.env (mode 600) and, for sending, the DKIM key; both stay when mail is off.
write_postfix() {
  local key=postfix/dkim/$MAIL_DOMAIN.private tls=/tls/$LE_STORE/${NEW[RAKAZO_HOST]}/${NEW[RAKAZO_HOST]} tmp
  [[ -n $MAIL_MODE ]] || return 0
  mkdir -p postfix/dkim
  chmod 755 postfix postfix/dkim
  if [[ $MAIL_MODE == *send && ! -f $key ]]; then
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$key.tmp" 2>/dev/null ||
      die "openssl could not create the DKIM key."
    chmod 644 "$key.tmp"
    mv "$key.tmp" "$key"
    DONE+=("New DKIM key $key (RSA 2048)")
  fi
  tmp=$(mktemp postfix/postfix.env.XXXXXX)
  {
    printf 'POSTFIX_myhostname=%s\n' "${NEW[RAKAZO_HOST]}"
    printf 'POSTFIX_mynetworks=127.0.0.0/8\n'
    printf 'POSTFIX_smtpd_client_restrictions=permit\n'
    printf 'POSTFIX_smtpd_sender_restrictions=reject_sender_login_mismatch\n'
    printf 'POSTFIX_smtpd_sender_login_maps=inline:{ @%s=rakazo@%s }\n' "$MAIL_DOMAIN" "${NEW[RAKAZO_HOST]}"
    printf 'POSTFIX_smtpd_relay_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination\n'
    printf 'POSTFIX_smtpd_recipient_restrictions=permit_mynetworks,permit_sasl_authenticated,reject_unauth_destination\n'
    printf 'POSTFIX_smtpd_sasl_auth_enable=no\n'
    printf 'POSTFIX_smtpd_tls_auth_only=yes\n'
    printf 'POSTFIX_smtpd_tls_security_level=may\n'
    printf 'POSTFIX_smtpd_tls_cert_file=%s.crt\n' "$tls"
    printf 'POSTFIX_smtpd_tls_key_file=%s.key\n' "$tls"
    printf 'POSTFIX_message_size_limit=26214400\n'
    printf 'POSTFIX_rakazo_destination_recipient_limit=1\n'
    if [[ $MAIL_MODE == receive* ]]; then
      printf 'POSTFIX_relay_domains=%s\n' "$MAIL_DOMAIN"
      printf 'POSTFIX_transport_maps=inline:{ %s=rakazo: }\n' "$MAIL_DOMAIN"
      printf 'INBOUND_SECRET=%s\n' "${NEW[INBOUND_EMAIL_SECRET]}"
    else
      printf 'POSTFIX_relay_domains=\nPOSTFIX_transport_maps=\nINBOUND_SECRET=\n'
    fi
    printf 'ALLOWED_SENDER_DOMAINS=%s\n' "$MAIL_DOMAIN"
    printf 'SMTPD_SASL_USERS=%s\n' "$([[ $MAIL_MODE != *send ]] || printf 'rakazo@%s:%s' "${NEW[RAKAZO_HOST]}" "$MAIL_PASSWORD")"
    printf 'DKIM_BACKEND=opendkim\nDKIM_SELECTOR=rakazo\n'
  } >"$tmp"
  mv "$tmp" postfix/postfix.env
  DONE+=("postfix/postfix.env written (mode 600)")
}

# --- Caddy ---------------------------------------------------------------------------------------

# render_caddy CUR|NEW – the template with domain and upstreams filled in
render_caddy() {
  local -n rc=$1
  local t up
  up=$(upstream_ip "${rc[RAKAZO_BIND]:-127.0.0.1}")
  t=$(<"$REPO_DIR/Caddyfile.example")
  t=${t//127.0.0.1:$DEFAULT_WEB_PORT /@WEB@ } t=${t//127.0.0.1:$DEFAULT_API_PORT /@API@ }
  t=${t//@WEB@/$up:${rc[RAKAZO_WEB_PORT]:-}} t=${t//@API@/$up:${rc[RAKAZO_API_PORT]:-}}
  printf '%s\n' "${t//rakazo.example.com/${rc[RAKAZO_HOST]:-}}"
}

# caddy_default FILE – only comments or the :80 site the caddy package ships?
caddy_default() {
  local s
  s=$(grep -v '^[[:space:]]*\(#\|$\)' "$1" 2>/dev/null | tr -s '[:space:]' ' ' || true)
  s=$(trim "$s")
  [[ -r $1 && (-z $s || $s == ':80 { root * /usr/share/caddy file_server }') ]]
}

show_diff() { # show_diff FILE NEW_CONTENT
  diff -u --label "$1 (now)" --label "$1 (new)" "$1" <(printf '%s' "$2") | sed 's/^/  /' || true
}

# caddy_write FILE CONTENT – backs FILE up and replaces it, with sudo after asking if needed.
# Returns 1 when the user declines sudo.
caddy_write() {
  local f=$1 tmp
  root_for "$f" || return 1
  tmp=$(mktemp)
  printf '%s' "$2" >"$tmp"
  if [[ -e $f ]]; then
    "${RUN[@]}" cp -p "$f" "$f.bak.$STAMP"
    "${RUN[@]}" cp "$tmp" "$f"
    DONE+=("$f written, previous file backed up as $f.bak.$STAMP")
  else
    "${RUN[@]}" install -m 644 "$tmp" "$f"
    DONE+=("$f written")
  fi
  rm -f "$tmp"
}

# caddy_manual FILE CONTENT – keeps CONTENT in the deployment directory and leaves the commands
# for the next steps.
caddy_manual() {
  local f=$1 new=$DEPLOY_DIR/${1##*/}.new
  printf '%s' "$2" >"$new"
  CADDY_TODO=()
  [[ ! -e $f ]] || CADDY_TODO+=("sudo cp -p $f $f.bak.$STAMP")
  CADDY_TODO+=("sudo cp $new $f   (or merge the Rakazo site block into it)"
    "sudo caddy validate --config $f --adapter caddyfile && sudo systemctl reload caddy")
  CADDY_ROW="not written; $new is ready (next steps)"
  printf 'Not written. %s holds the new version; the commands are in the next steps.\n' "$new"
}

# Writes the Caddy file from the template: directly when it is missing or the package default,
# otherwise after showing the diff. Then caddy validate and, if wanted, a reload.
step_caddy() {
  local f=$CADDY_FILE content def=n out
  CADDY_ROW="" CADDY_TODO=()
  remote_proxy NEW && return 0
  section Caddy
  content=$(render_caddy NEW)$'\n'
  if ! command -v caddy >/dev/null; then
    printf 'Caddy is not installed. Install it (https://caddyserver.com/docs/install), then run this\n'
    printf 'script again: it writes %s.\n' "$f"
    CADDY_ROW="not installed"
    CADDY_TODO=("install Caddy (https://caddyserver.com/docs/install), then run $SELF again")
    return 0
  fi
  if [[ -f $f ]] && cmp -s "$f" <(printf '%s' "$content"); then
    printf '%s is up to date.\n' "$f"
    CADDY_ROW="$f, up to date"
    return 0
  fi
  if [[ -e $f ]] && ! caddy_default "$f"; then
    printf '%s has other content:\n' "$f"
    show_diff "$f" "$content"
    ! grep -qF "${NEW[RAKAZO_HOST]} {" "$f" || def=y
    ask_yn "Replace it (backed up first)" "$def" || { caddy_manual "$f" "$content"; return 0; }
  fi
  caddy_write "$f" "$content" || { caddy_manual "$f" "$content"; return 0; }
  CADDY_ROW="$f written from Caddyfile.example"
  if ! out=$(caddy validate --config "$f" --adapter caddyfile 2>&1); then
    # Caddy logs as JSON: show the messages of its errors and any plain lines.
    sed -n -e '/^{/{s/^.*"level":"error".*"msg":"\([^"]*\)".*/  \1/p;d;}' -e 's/^/  /p' <<<"$out" | tail -n 5 >&2
    warn "caddy validate rejects $f."
    if [[ -e $f.bak.$STAMP ]] && ask_yn "Put back the previous $f" y; then
      "${RUN[@]}" cp "$f.bak.$STAMP" "$f"
      DONE+=("$f restored from $f.bak.$STAMP after caddy validate failed")
    fi
    CADDY_ROW="caddy validate fails: fix $f (next steps)"
    CADDY_TODO=("fix $f, then: sudo caddy validate --config $f --adapter caddyfile && sudo systemctl reload caddy")
    return 0
  fi
  printf 'caddy validate: the configuration is valid.\n'
  if ! systemctl is-active --quiet caddy 2>/dev/null; then
    CADDY_TODO=("sudo systemctl enable --now caddy   (Caddy is not running)")
  elif ask_yn "Reload Caddy now (sudo systemctl reload caddy)" y && as_root systemctl reload caddy; then
    DONE+=("Caddy reloaded")
    CADDY_ROW+=", reloaded"
  else
    CADDY_TODO=("sudo systemctl reload caddy")
  fi
}

# Creates Caddy's certificates folder for Postfix's mount before Docker would create it as root.
caddy_certs() {
  [[ -n $MAIL_MODE && ! -d $CADDY_CERTS ]] || return 0
  printf 'Postfix mounts %s; created by Docker it would belong to root and\n' "$CADDY_CERTS"
  printf 'Caddy could no longer store certificates.\n'
  if ask_yn "Create it as Caddy's user if missing (sudo -u caddy mkdir -p)" y &&
    if ((EUID == 0)); then runuser -u caddy -- mkdir -p -m 700 "$CADDY_CERTS"
    else sudo -u caddy mkdir -p -m 700 "$CADDY_CERTS"; fi; then
    DONE+=("$CADDY_CERTS exists for Caddy")
  else
    CADDY_TODO+=("sudo -u caddy mkdir -p -m 700 $CADDY_CERTS")
  fi
}

# --- DNS -----------------------------------------------------------------------------------------

public_ipv4() {
  valid_ipv4 "$1" && [[ ! $1 =~ ^(0|10|127)\. && ! $1 =~ ^(169\.254|192\.168)\. &&
    ! $1 =~ ^172\.(1[6-9]|2[0-9]|3[01])\. && ! $1 =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]]
}
public_ipv6() { [[ ${1,,} =~ ^[23][0-9a-f]{0,3}:[0-9a-f:]+$ ]]; }

# Public addresses of this host: the source address towards the internet if that is public, else
# empty (the DNS text then shows a placeholder).
detect_ips() {
  local a
  a=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' || true)
  if public_ipv4 "$a"; then IPV4=$a; fi
  a=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | sed -n 's/.* src \([0-9a-f:]*\).*/\1/p' || true)
  if public_ipv6 "$a"; then IPV6=${a,,}; fi
}

# The DKIM record value for the key in postfix/dkim/: the public key as base64 DER
# (SubjectPublicKeyInfo).
dkim_value() {
  local p
  p=$(openssl pkey -in "postfix/dkim/$MAIL_DOMAIN.private" -pubout -outform DER 2>/dev/null | base64 -w 0 || true)
  printf 'v=DKIM1; k=rsa; p=%s' "${p:-<key missing: run generate-env.sh>}"
}

# dns_records CUR|NEW MAIL_MODE – "name|type|priority|value" for every record the setup needs
dns_records() {
  local -n dr=$1
  local m=$2 h=${dr[RAKAZO_HOST]}
  if remote_proxy dr; then
    printf '%s|A||<IP of your reverse proxy>\n' "$h"
    return 0
  fi
  printf '%s|A||%s\n' "$h" "${IPV4:-<public IPv4 of this host>}"
  [[ -z $IPV6 ]] || printf '%s|AAAA||%s\n' "$h" "$IPV6"
  [[ $m != receive* ]] || printf '%s|MX|10|%s\n' "$MAIL_DOMAIN" "$h"
  if [[ $m == *send ]]; then
    printf '%s|TXT||v=spf1 a:%s -all\n' "$MAIL_DOMAIN" "$h"
    printf 'rakazo._domainkey.%s|TXT||%s\n' "$MAIL_DOMAIN" "$(dkim_value)"
    printf '_dmarc.%s|TXT||v=DMARC1; p=quarantine\n' "$MAIL_DOMAIN"
  fi
}

# txt_strings VALUE – VALUE as quoted strings of at most 255 characters
txt_strings() {
  local s=$1 out=""
  while ((${#s})); do out+=" \"${s:0:255}\"" s=${s:255}; done
  printf '%s' "${out# }"
}

# The records, PTR and ports as copy-ready text, for the summary and dns-records.txt.
dns_text() {
  local name type prio value w=4 dkim="" m=$MAIL_MODE rows=() r
  mapfile -t rows < <(dns_records NEW "$m")
  for r in "${rows[@]}"; do name=${r%%|*}; ((${#name} <= w)) || w=${#name}; done
  printf '%-*s  %-4s  %-4s  %s\n' "$w" Name Type Prio Value
  for r in "${rows[@]}"; do
    IFS='|' read -r name type prio value <<<"$r"
    printf '%-*s  %-4s  %-4s  %s\n' "$w" "$name" "$type" "$prio" "$value"
    [[ $value != v=DKIM1* ]] || dkim=$value
  done
  if [[ -n $dkim ]]; then
    printf '\nThe DKIM value as strings of at most 255 characters, for zone files and providers that want them:\n'
    printf '%s\n' "$(txt_strings "$dkim")"
  fi
  if [[ $m == *send ]]; then
    printf '\nReverse DNS (PTR), set at your hoster for the IPv4 address of this host:\n'
    printf '%s  →  %s\n' "${IPV4:-<public IPv4 of this host>}" "${NEW[RAKAZO_HOST]}"
  fi
  printf '\nNames are complete; some DNS providers want only the part before the zone.\n'
  if remote_proxy NEW; then
    printf 'Ports: your reverse proxy serves 80/tcp and 443/tcp.\n'
    return 0
  fi
  printf 'Ports: open 80/tcp and 443/tcp (443/udp for HTTP/3)%s.\n' "$([[ $m != receive* ]] || echo ' and 25/tcp inbound')"
  if [[ $m == receive* ]]; then
    printf 'Port 25 is published on IPv4 only, past ufw: ufw rules neither open nor close it.\n'
  fi
  [[ $m != *send ]] || printf 'Sending needs outbound 25/tcp, which many hosters block until you ask.\n'
}

# --- Result --------------------------------------------------------------------------------------

section() { printf '\n== %s ==\n' "$1"; }
row() { printf '  %-17s %s\n' "$1" "$2"; }

summary() {
  local k ignored=() notes=() m=$MAIL_MODE
  section "Done in $DEPLOY_DIR"
  for k in "${DONE[@]}"; do printf '  %s\n' "$k"; done

  section Summary
  row Release "${NEW[RAKAZO_IMAGE_TAG]}"
  row Domain "https://${NEW[RAKAZO_HOST]}"
  row Ports "web ${NEW[RAKAZO_BIND]}:${NEW[RAKAZO_WEB_PORT]}, API ${NEW[RAKAZO_BIND]}:${NEW[RAKAZO_API_PORT]}"
  [[ -z ${NEW[TRUSTED_PROXIES]} ]] || row "Trusted proxies" "${NEW[TRUSTED_PROXIES]}"
  row Computers "$([[ ${NEW[SANDBOX_IDLE_MS]} == 0 ]] && echo 'keep running when idle' || echo 'stop when idle')"
  if [[ -n $m ]]; then
    row "Mail server" "Postfix $(case $m in receive) echo receives ;; send) echo sends ;; *) echo 'receives and sends' ;; esac) for $MAIL_DOMAIN"
  fi
  if [[ $m == *send ]]; then row Email "Postfix on this host, as ${NEW[EMAIL_FROM]}"
  else row Email "${NEW[EMAIL_PROVIDER]:-none}"; fi
  [[ -z $(edge_val INBOUND_EMAIL_DOMAIN) ]] || row "Bot email" "${NEW[INBOUND_EMAIL_DOMAIN]}"
  row SSO "${NEW[OIDC_ISSUER]:-off}"
  [[ -z $(edge_val SCIM_BEARER_TOKEN) ]] || row SCIM on
  row Signup "$(case $SIGNUP_MODE in 1) echo closed ;; 2) echo "allowlist (${NEW[SIGNUP_ALLOWLIST]})" ;; 3) echo open ;; esac)"
  row Admins "${NEW[RAKAZO_ADMIN_EMAILS]:-none}"
  row Model "$(deployment_model NEW)"
  row "App catalog" "$(case $CATALOG_MODE in 1) echo none ;; 2) echo Composio ;; 3) echo "Pipedream (${NEW[PIPEDREAM_ENVIRONMENT]})" ;; esac)"
  [[ -z $CADDY_ROW ]] || row Caddy "$CADDY_ROW"

  if [[ -n ${CUR[RAKAZO_IMAGE_TAG]:-} && ${CUR[RAKAZO_IMAGE_TAG]} != "${NEW[RAKAZO_IMAGE_TAG]}" ]]; then
    notes+=("Images change to ${NEW[RAKAZO_IMAGE_TAG]}: in $DEPLOY_DIR docker compose pull && docker compose up -d")
  fi
  if ((PORTS_CHANGED)) && { remote_proxy NEW || ((${#CADDY_TODO[@]})); }; then
    notes+=("Ports changed: update the reverse proxy (next steps), otherwise the domain answers 502.")
  fi
  if [[ $OLD_MAIL == receive* && $m == send ]]; then
    notes+=("Postfix no longer receives mail for $MAIL_DOMAIN: remove its MX record if nothing else uses it.")
  fi
  if [[ -n $OLD_MAIL && -z $m ]]; then
    notes+=("Mail server off: in $DEPLOY_DIR docker compose rm -sf postfix stops and removes its container.")
    notes+=("postfix/ stays with its DKIM key; remove the mail DNS records if nothing else uses them.")
  fi
  if ! on_edge; then
    for k in "${EDGE_KEYS[@]}"; do
      if [[ -n ${NEW[$k]} ]]; then ignored+=("$k"); fi
    done
    ((${#ignored[@]} == 0)) ||
      notes+=("Kept in .env, but only edge or a release after v0.8.0 reads: $(join "${ignored[@]}" | sed 's/,/, /g').")
  fi
  for k in "${DROPPED_KEYS[@]}"; do notes+=("Removed $k from .env: fixed in docker-compose.yml or no longer needed."); done
  if ((${#notes[@]})); then
    section Attention
    for k in "${notes[@]}"; do printf '  ! %s\n' "$k"; done
  fi
}

# step TITLE – numbered heading in the next steps
step() { STEP=$((STEP + 1)); printf '  %d. %s\n' "$STEP" "$1"; }

next_steps() {
  local cap scim inbound up c m=$MAIL_MODE host=${NEW[RAKAZO_HOST]}
  STEP=0
  scim=$(edge_val SCIM_BEARER_TOKEN) inbound=$(edge_val INBOUND_EMAIL_DOMAIN)
  up=$(upstream_ip "${NEW[RAKAZO_BIND]}")

  section "Once per host"
  step DNS
  printf '     Set the records under "DNS records" above, also in %s/dns-records.txt.\n' "$DEPLOY_DIR"
  if remote_proxy NEW; then
    [[ ${NEW[RAKAZO_BIND]} != 0.0.0.0 ]] || up="<IP of this host>"
    step "Reverse proxy (${NEW[TRUSTED_PROXIES]#local-networks,})"
    cat <<EOF
     Terminates TLS for ${NEW[RAKAZO_HOST]} and forwards /health, /api/* and /rpc/* to
     $up:${NEW[RAKAZO_API_PORT]}, everything else to $up:${NEW[RAKAZO_WEB_PORT]}, with
     X-Forwarded-For set to the client. Caddy template: ${CADDY_EXAMPLE_URL}
     Allow only the proxy to reach these ports; they serve plain HTTP.
EOF
  fi
  if [[ $m == *send ]]; then
    step "Reverse DNS and port 25"
    printf '     At your hoster: PTR of %s set to %s, and outbound 25/tcp allowed.\n' \
      "${IPV4:-<public IPv4 of this host>}" "$host"
  fi
  if ((${#CADDY_TODO[@]})); then
    step Caddy
    for c in "${CADDY_TODO[@]}"; do printf '       %s\n' "$c"; done
  fi
  step "Docker daemon (recommended)"
  cat <<'EOF'
     Every Private bot and every space gets its own Docker network; the built-in address pools hold
     only about 30. Computers are created by the supervisor, so only the daemon rotates their logs.
     In /etc/docker/daemon.json (if it exists, add only the keys; the range must not overlap your
     LAN, VPN or cloud network, see ip route):
       {
         "default-address-pools": [{ "base": "10.200.0.0/16", "size": 24 }],
         "log-driver": "json-file",
         "log-opts": { "max-size": "5m", "max-file": "3" }
       }
       sudo dockerd --validate --config-file /etc/docker/daemon.json && sudo systemctl restart docker
EOF
  cap=$(pool_capacity)
  [[ -z $cap ]] || printf '     Address pools are already configured here: room for %s networks.\n' "$cap"
  step "Computer firewall (recommended)"
  cat <<EOF
     Keeps computers away from the host, the LAN and cloud metadata (169.254.169.254); without it
     they have open network access. Docker Engine with iptables; read the script first:
       curl -fsSLo /tmp/restrict-computer-egress.sh \\
         https://raw.githubusercontent.com/elie222/rakazo/main/infra/compose/restrict-computer-egress.sh
       sudo bash /tmp/restrict-computer-egress.sh
     If the stack already runs: cd $DEPLOY_DIR && docker compose up -d --force-recreate supervisor
EOF

  section Start
  step "cd $DEPLOY_DIR && docker compose up -d"
  step "$SELF --check"
  if ((SIGNUP_MODE == 1)) && [[ -z $scim ]]; then
    step "$SELF --owner   the admin account with a password, the only way in while signup is closed"
  else
    step "$SELF --owner   the admin account with a password"
  fi

  if [[ -n ${NEW[OIDC_ISSUER]}$scim ]]; then
    section "At the identity provider"
    if [[ -n ${NEW[OIDC_ISSUER]} ]]; then
      row "Redirect URI" "https://${NEW[RAKAZO_HOST]}/api/auth/callback/oidc"
      row "ID token" "needs the email claim (Entra ID: Token configuration → optional claim email)"
      if [[ -n ${NEW[OIDC_ALLOW_SIGNUP_BYPASS]} ]]; then
        row Access "everyone the provider lets in can sign up with SSO; restrict it there"
        row "" "(Entra ID: Enterprise application → Properties → Assignment required = Yes)"
        row "Admin account" "signs in with its password; SSO accounts stay unverified and cannot be admins"
      else
        row Access "the provider must send email_verified=true"
        case $SIGNUP_MODE in
          1) [[ -n $scim ]] || row "" "signup is closed, so SSO cannot create new accounts" ;;
          2) row "" "addresses on the allowlist (${NEW[SIGNUP_ALLOWLIST]}) create their account with SSO" ;;
        esac
        row "Admin account" "signs in with its password first, then Link SSO in the account settings"
      fi
    fi
    if [[ -n $scim ]]; then
      row SCIM "base URL https://${NEW[RAKAZO_HOST]}/api/auth/scim/v2, token: grep ^SCIM_BEARER_TOKEN= $DEPLOY_DIR/.env"
      row "" "(Entra ID: Enterprise application → Provisioning → Automatic, Tenant URL and Secret Token)"
    fi
  fi

  if [[ -n $inbound && $m != receive* ]]; then
    section "Bot email"
    printf '  Route all mail for %s to a relay (e.g. Cloudflare Email Routing) that posts\n' "$inbound"
    printf '  each message to https://%s/api/v1/email/inbound?to=<recipient> with\n' "${NEW[RAKAZO_HOST]}"
    printf '  Authorization: Bearer <INBOUND_EMAIL_SECRET>. Guide: %s\n' "$INBOUND_EMAIL_DOCS"
  fi

  section Later
  row Update "git pull in $REPO_DIR, then $SELF"
  row "" "and in $DEPLOY_DIR: docker compose pull && docker compose up -d"
  row "Change settings" "$SELF, then in $DEPLOY_DIR: docker compose up -d"
  row Check "$SELF --check"
  if on_edge; then
    row "Lock someone out" "$SELF --deactivate EMAIL (undo with --reactivate)"
  fi
}

generate() {
  command -v openssl >/dev/null || die "openssl is missing."
  [[ -t 0 ]] || die "Please run interactively in a terminal."
  printf 'Rakazo – set up the deployment in %s\n' "$DEPLOY_DIR"
  if legacy_install; then migrate_legacy; else enter_deploy_dir; fi
  load_env
  load_postfix_env
  if pg_data_exists && [[ -z ${CUR[POSTGRES_PASSWORD]:-} || -z ${CUR[ENCRYPTION_KEY]:-} ]]; then
    die "$DEPLOY_DIR/data/postgres already holds a database, but .env lacks POSTGRES_PASSWORD or
ENCRYPTION_KEY. New values would not match (sign-in fails, stored credentials become unreadable).
Restore the old .env from its backup or delete data/ deliberately."
  fi

  if [[ -f $ENV_FILE ]]; then
    printf 'Existing .env found: values in [ ] are the current ones, secrets are kept.\n'
  fi
  printf 'Enter keeps the value in [ ], "-" clears a field.\n'

  step_images
  step_domain
  step_ports
  step_computers
  step_mail
  step_email
  step_bot_email
  step_sso
  step_directory
  step_admins
  step_signups
  step_catalog
  step_models
  step_secrets
  deploy_files
  write_env
  write_postfix
  mkdir -p data/postgres data/app data/web-assets credentials
  step_caddy
  caddy_certs
  detect_ips
  { printf '# DNS records for Rakazo, written by generate-env.sh on %s\n\n' "$(date '+%Y-%m-%d %H:%M')"; dns_text; } \
    >dns-records.txt
  DONE+=("dns-records.txt written")
  hand_over

  summary
  section "DNS records"
  dns_text | sed 's/^./  &/'
  next_steps
}

# --- Owner ---------------------------------------------------------------------------------------

owner() {
  local email pw pw2 res admins
  [[ -t 0 ]] || die "Please run interactively in a terminal."
  [[ -f $ENV_FILE ]] || die "No .env found. Run ./generate-env.sh first."
  load_env
  [[ -n $(docker compose ps -q --status running api 2>/dev/null) ]] ||
    die "The api service is not running. Start the stack first: docker compose up -d"
  admins=${CUR[RAKAZO_ADMIN_EMAILS]:-}
  split_list "$admins"
  printf 'Creates a verified account with a password, or verifies an existing one if the password\n'
  printf 'matches. An account that is already verified stays unchanged.\n'
  while :; do
    ask email "Account email" "${LIST[0]:-}"
    email=${email,,}
    valid_email "$email" && break
    warn "\"$email\" is not an email address."
  done
  while :; do
    IFS= read -r -s -p "Password (at least 16 characters): " pw || die "Input aborted."
    printf '\n'
    ((${#pw} >= 16)) || { warn "The password needs at least 16 characters."; continue; }
    IFS= read -r -s -p "Repeat the password: " pw2 || die "Input aborted."
    printf '\n'
    [[ $pw == "$pw2" ]] && break
    warn "The passwords do not match."
  done
  if ! res=$(OWNER_EMAIL=$email OWNER_PASSWORD=$pw docker compose exec -T -e OWNER_EMAIL -e OWNER_PASSWORD \
    api node dist/cli/bootstrap-owner.js 2>&1); then
    printf '%s\n' "$res" | grep -v '^\s*at ' | sed 's/^/  /' >&2 || true
    die "Account was not created."
  fi
  if [[ $res == *"Account verified"* ]]; then
    printf '\nAccount %s is ready. Sign in at https://%s\n' "$email" "${CUR[RAKAZO_HOST]}"
  else
    printf '\n%s already had a verified account; it is unchanged, the password was not set.\n' "$email"
  fi
  [[ ,${admins// /}, == *,"$email",* ]] ||
    printf 'Not in RAKAZO_ADMIN_EMAILS, so no admin rights; add it with ./generate-env.sh if wanted.\n'
  if [[ ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} == true ]]; then
    printf 'The SSO provider sends no email_verified, so this account cannot be linked to SSO; it signs\n'
    printf 'in with its password.\n'
  elif [[ -n ${CUR[OIDC_ISSUER]:-} ]]; then
    printf 'For SSO: sign in with the password, then choose Link SSO in the account settings.\n'
  fi
}

# account_status deactivate|reactivate EMAIL
account_status() {
  local action=$1 email=${2:-} res
  email=${email,,}
  valid_email "$email" || die "Usage: ./generate-env.sh --$action <email>"
  [[ -f $ENV_FILE ]] || die "No .env found. Run ./generate-env.sh first."
  [[ -n $(docker compose ps -q --status running api 2>/dev/null) ]] ||
    die "The api service is not running. Start the stack first: docker compose up -d"
  docker compose exec -T api node -e \
    "process.exit(require('fs').existsSync('dist/cli/account-status.js')?0:1)" >/dev/null 2>&1 ||
    die "The running images cannot lock accounts: that needs edge or a release after v0.8.0."
  if ! res=$(docker compose exec -T api node dist/cli/account-status.js "$action" "$email" 2>&1); then
    printf '%s\n' "$res" | grep -v '^\s*at ' | sed 's/^/  /' >&2 || true
    die "Account $email was not changed."
  fi
  case $res in
    *"Already deactivated"*) printf '%s was already locked.\n' "$email" ;;
    *"Already active"*) printf '%s is already active.\n' "$email" ;;
    *Deactivated*)
      printf '%s is locked: sign-ins, paired computers and runs ended, routines are skipped.\n' "$email"
      printf 'Bots, chats and files stay. Spaces shared by others pass what they made there to the owner.\n'
      ;;
    *Reactivated*)
      printf '%s is unlocked: own spaces and routines are back. Shared spaces need a new invite.\n' "$email"
      ;;
    *) printf '%s\n' "$res" ;;
  esac
}

# --- Check ---------------------------------------------------------------------------------------

ERRORS=0
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  ERROR   %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
hint() { printf '  note    %s\n' "$*"; }
# For features only edge has so far: an error on edge, a note with older images.
edge_bad() { if [[ ${CUR[RAKAZO_IMAGE_TAG]:-} == edge ]]; then bad "$@"; else hint "$@"; fi; }

# http_probe URL [curl options …] – prints the headers, the last 3 characters are the status
# (000 = no connection).
http_probe() {
  local url=$1
  shift
  { curl -sS -o /dev/null -D - -w '%{http_code}' --max-time 10 "$@" "$url" 2>/dev/null || true; } | tr -d '\r'
}

cors_allows() { # cors_allows BASE_URL ORIGIN – preflight like the browser sends on sign-in
  local res
  res=$(http_probe "$1/api/auth/capabilities" -X OPTIONS -H "Origin: $2" -H 'Access-Control-Request-Method: POST')
  grep -qiFx "access-control-allow-origin: $2" <<<"$res"
}

check_cors() { # check_cors BASE_URL ORIGIN label
  if cors_allows "$1" "$2"; then
    ok "$3: CORS allows origin $2"
  else
    bad "$3: CORS does not allow origin $2 (check WEB_ORIGIN/BETTER_AUTH_URL/API_URL)"
  fi
  if cors_allows "$1" https://foreign.example; then
    bad "$3: CORS also allows a foreign origin"
  else
    ok "$3: foreign origins are rejected"
  fi
}

# health_has JSON NAME – active connector in /internal/health: "name":true (v0.8) or in "integrations"
health_has() {
  local re="\"integrations\":\\[[^]]*\"$2\""
  [[ $1 == *"\"$2\":true"* || $1 =~ $re ]]
}

# Pings the Docker daemon from inside the supervisor, over the same socket it uses for computers.
DOCKER_PING_JS="require('http').get({socketPath:'/var/run/docker.sock',path:'/_ping'},r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"
# Lists the models of the OpenAI-compatible server the way the API reaches it.
LOCAL_MODELS_JS="fetch(process.env.RAKAZO_LOCAL_MODELS_URL.replace(/\\/\$/,'')+'/models',{headers:{authorization:'Bearer '+(process.env.RAKAZO_LOCAL_MODELS_API_KEY||'local')},signal:AbortSignal.timeout(5000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

# check_scim BASE_URL label – lists one user with the token, as the identity provider does
check_scim() {
  local res
  res=$(http_probe "$1/api/auth/scim/v2/Users?count=1" \
    -H @<(printf 'Authorization: Bearer %s\n' "${CUR[SCIM_BEARER_TOKEN]}"))
  case ${res: -3} in
    200) ok "$2: SCIM accepts SCIM_BEARER_TOKEN" ;;
    401 | 403) bad "$2: SCIM rejects SCIM_BEARER_TOKEN (after a change: docker compose up -d)" ;;
    404) edge_bad "$2: no SCIM endpoint (needs edge; after a change: docker compose up -d)" ;;
    000) bad "$2: no answer from the SCIM endpoint" ;;
    *) bad "$2: SCIM answers ${res: -3}" ;;
  esac
}

# check_inbound BASE_URL label – posts without the secret: 401 means the relay endpoint is there
check_inbound() {
  local res
  res=$(http_probe "$1/api/v1/email/inbound?to=check@${CUR[INBOUND_EMAIL_DOMAIN]}" -X POST \
    -H 'Content-Type: message/rfc822')
  case ${res: -3} in
    401) ok "$2: the bot email endpoint is there and requires INBOUND_EMAIL_SECRET" ;;
    404) edge_bad "$2: no bot email endpoint (needs edge; after a change: docker compose up -d)" ;;
    000) bad "$2: no answer from the bot email endpoint" ;;
    *) bad "$2: the bot email endpoint answers ${res: -3} instead of 401 without the secret" ;;
  esac
}

# Asks the screen proxy in the web container about an invalid capability, which it has the API
# verify: 403 with its own message means /novnc/ reaches the proxy and the proxy reaches the API.
check_screen() { # check_screen BASE_URL label [curl options …]
  local res
  res=$({ curl -sS --max-time 10 -w '\n%{http_code}' "${@:3}" "$1/novnc/session/view/1.check/" 2>/dev/null || true; } | tr -d '\r')
  case ${res: -3} in
    403)
      if [[ $res == *"screen capability"* ]]; then ok "$2: /novnc/ reaches the screen proxy, which reaches the API"
      else bad "$2: /novnc/ is rejected before it reaches the screen proxy (host check?)"; fi
      ;;
    503) bad "$2: the screen proxy cannot reach the API (docker compose logs web)" ;;
    *) bad "$2: /novnc/ answers ${res: -3} instead of 403 from the screen proxy (check routing)" ;;
  esac
}

# Connects to SMTP_URL the way Rakazo does (nodemailer from the app image, STARTTLS required,
# certificate verified, the same timeouts), logs in and quits without sending. Prints no secrets.
SMTP_VERIFY_JS='const u=new URL(process.env.SMTP_URL);if(u.protocol==="smtp:")u.searchParams.set("requireTLS","true");for(const [k,v] of [["connectionTimeout",1e4],["greetingTimeout",1e4],["socketTimeout",3e4]])if(!u.searchParams.has(k))u.searchParams.set(k,String(v));require(require.resolve("nodemailer",{paths:["/app/packages/adapters"]})).createTransport(u.href).verify().then(()=>process.exit(0),e=>{console.error([e.code,e.responseCode,e.message].filter(Boolean).join(" ").replace(/\/\/[^@\s]*@/g,"//***@"));process.exit(1)})'

check_deploy() {
  local f owner files=(docker-compose.yml) differ=()
  printf 'Deployment (%s)\n' "$DEPLOY_DIR"
  owner=$(stat -c %U .)
  if [[ $owner == "$(id -un)" ]]; then ok "owned by $owner"
  else hint "owned by $owner, not $(id -un): the script and docker compose need sudo there"; fi
  [[ $(stat -c %a .) != *[2367] ]] || bad "$DEPLOY_DIR is writable for everyone: chmod o-w $DEPLOY_DIR"
  [[ -d data && -d credentials ]] || hint "data/ or credentials/ is missing: docker compose creates it owned by root"
  [[ ! $REPO_DIR -ef . ]] || return 0
  [[ -z $OLD_MAIL ]] || files+=(postfix/rakazo.sh postfix/rakazo-inbound-email)
  for f in "${files[@]}"; do
    if [[ ! -f $f ]]; then bad "$f is missing: $SELF copies it"
    elif ! cmp -s "$REPO_DIR/$f" "$f"; then differ+=("$f"); fi
  done
  if ((${#differ[@]})); then
    hint "differs from the checkout: ${differ[*]}; $SELF copies the new version (a changed copy is backed up)"
  else
    ok "${files[*]} match the checkout"
  fi
  [[ ! -f $REPO_DIR/$ENV_FILE ]] || hint "$REPO_DIR/.env is left from the old layout and unused"
  for f in "$REPO_DIR"/migrated-*; do
    if [[ -d $f ]]; then hint "$f holds the files of the old layout: delete it once this install works"; fi
  done
}

check_caddy() {
  local f=$CADDY_FILE web=$1 api=$2 host=${CUR[RAKAZO_HOST]:-}
  printf '\nCaddy\n'
  if remote_proxy CUR; then
    hint "reverse proxy on another machine (${CUR[TRUSTED_PROXIES]#local-networks,}): checked through https://$host below"
    return 0
  elif [[ ! -r $f ]]; then
    hint "$f not found or not readable: $SELF writes it"
    return 0
  fi
  if [[ $(<"$f") == "$(render_caddy CUR)" ]]; then ok "$f is what $SELF writes"
  else hint "$f differs from what $SELF writes (template, .env or changes here): it shows the diff"; fi
  if ! grep -qF "$host {" "$f"; then
    bad "$f has no site block for $host: $SELF writes it, then reload Caddy"
  elif grep -q "reverse_proxy $web " "$f" && grep -q "reverse_proxy $api " "$f"; then
    ok "$f serves $host and points to $web and $api"
  else
    bad "$f does not point to $web/$api: $SELF fixes the upstreams, then reload Caddy"
  fi
}

# Sends a test mail from inside the Postfix container to an unclaimed name; Rakazo accepts and
# drops it. It must leave the queue as sent.
check_inbound_mail() {
  local rcpt res line i
  rcpt=check-$(openssl rand -hex 6)@$MAIL_DOMAIN
  if ! printf 'From: <postmaster@%s>\nTo: <%s>\nSubject: generate-env.sh --check\nMessage-ID: <%s.%s@%s>\n\n%s\n' \
    "$MAIL_DOMAIN" "$rcpt" "${rcpt%@*}" "$STAMP" "$1" "Test of generate-env.sh --check; nobody has this address." |
    docker compose exec -T postfix sendmail -f '<>' "$rcpt" >/dev/null 2>&1; then
    bad "inbound: sendmail in the postfix container fails (docker compose logs postfix)"
    return
  fi
  for ((i = 0; i < 30; i++)); do
    res=$(docker compose exec -T postfix postqueue -p 2>/dev/null || true)
    [[ $res == *"$rcpt"* ]] || break
    sleep 1
  done
  if [[ $res == *"$rcpt"* ]]; then
    line=$(grep -B 1 -F "$rcpt" <<<"$res" | grep -o '(.*)' | head -n 1 || true)
    bad "inbound: a test mail to $rcpt is still queued ${line:-(docker compose logs postfix)}"
    return
  fi
  line=$(docker compose logs --no-log-prefix --since 10m postfix 2>/dev/null | grep -F "to=<$rcpt>" | tail -n 1 || true)
  case $line in
    *status=sent*) ok "inbound: Postfix took a test mail for $rcpt and handed it to Rakazo" ;;
    *status=*) bad "inbound: test mail to $rcpt: ${line#*status=}" ;;
    *) ok "inbound: a test mail for $rcpt left the queue (no delivery line in the logs)" ;;
  esac
}

# check_mail RUNNING – the mail settings and, with the stack running, certificate, a test mail and
# a login as Rakazo sends
check_mail() {
  local m=$OLD_MAIL host=${CUR[RAKAZO_HOST]:-} pw=${PF[SMTPD_SASL_USERS]:-} state errors=$ERRORS res uid end
  [[ ,${CUR[COMPOSE_PROFILES]:-}, == *,mail,* ]] || return 0
  printf '\nMail server (%s)\n' "$host"
  if [[ -z $m ]]; then
    bad "COMPOSE_PROFILES=mail, but postfix/postfix.env is missing or neither receives nor sends: $SELF"
    return 0
  fi
  [[ $m != receive* || ${CUR[RAKAZO_IMAGE_TAG]:-} == edge ]] || bad "receiving bot email needs edge"
  caddy_packaged || bad "Caddy is not the packaged service with its data in /var/lib/caddy: Postfix finds no certificate"
  [[ $(stat -c %a postfix/postfix.env) == 600 ]] || bad "postfix/postfix.env is not mode 600: chmod 600 postfix/postfix.env"
  [[ ${PF[POSTFIX_myhostname]:-} == "$host" ]] || bad "postfix/postfix.env is not for $host: $SELF"
  valid_host "$MAIL_DOMAIN" || bad "postfix/postfix.env has no valid ALLOWED_SENDER_DOMAINS: $SELF"
  if [[ $m == receive* ]]; then
    [[ ${CUR[INBOUND_EMAIL_DOMAIN]:-} == "$MAIL_DOMAIN" ]] ||
      bad "INBOUND_EMAIL_DOMAIN is not the mail domain $MAIL_DOMAIN: $SELF"
    [[ ${PF[INBOUND_SECRET]:-} == "${CUR[INBOUND_EMAIL_SECRET]:-}" ]] ||
      bad "INBOUND_SECRET in postfix/postfix.env differs from INBOUND_EMAIL_SECRET: Rakazo would answer 401"
  fi
  if [[ $m == *send ]]; then
    [[ ${CUR[EMAIL_PROVIDER]:-} == smtp &&
      ${CUR[SMTP_URL]:-} == "smtp://rakazo%40$host:${pw#*:}@postfix:587/?tls.servername=$host" ]] ||
      bad "SMTP_URL does not point to the SASL user of postfix/postfix.env: $SELF"
    [[ ${CUR[EMAIL_FROM]:-} =~ @([^@[:space:]\>]+) && ${BASH_REMATCH[1],,} == "$MAIL_DOMAIN" ]] ||
      bad "EMAIL_FROM is not an address @$MAIL_DOMAIN: Postfix rejects it"
    openssl pkey -in "postfix/dkim/$MAIL_DOMAIN.private" -noout 2>/dev/null ||
      bad "postfix/dkim/$MAIL_DOMAIN.private is missing or no key: $SELF creates it"
  fi
  ((ERRORS > errors)) || ok "postfix/postfix.env and .env match"

  [[ -n $1 ]] || return 0
  state=$(docker compose ps --format '{{if .Health}}{{.Health}}{{else}}{{.State}}{{end}}' postfix 2>/dev/null || true)
  case $state in
    healthy | running | starting) ;;
    "") bad "the postfix container is not running (docker compose up -d; docker compose logs postfix)"; return 0 ;;
    *) hint "postfix is $state: mail tests skipped (docker compose logs postfix)"; return 0 ;;
  esac
  uid=$(docker compose exec -T postfix stat -c %u /tls 2>/dev/null | tr -d '\r' || true)
  [[ $uid != 0 ]] ||
    bad "$CADDY_CERTS belongs to root, so Caddy cannot store certificates: sudo chown caddy:caddy $CADDY_CERTS"
  res=$(docker compose exec -T postfix cat "${PF[POSTFIX_smtpd_tls_cert_file]:-}" 2>/dev/null || true)
  if ! openssl x509 -noout -checkhost "$host" <<<"$res" 2>/dev/null | grep -q 'does match'; then
    bad "Postfix sees no certificate for $host at ${PF[POSTFIX_smtpd_tls_cert_file]:-?} (Caddy: sudo journalctl -u caddy)"
  else
    end=$(openssl x509 -noout -enddate <<<"$res" | cut -d= -f2)
    ok "Postfix sees the certificate for $host, valid until $end"
  fi
  [[ $m != receive* ]] || check_inbound_mail "$host"
  [[ $m == *send ]] || return 0
  if res=$(docker compose exec -T api node -e "$SMTP_VERIFY_JS" 2>&1); then
    ok "submission: the API logs in to postfix:587 with STARTTLS and the certificate of $host, as Rakazo sends"
  else
    bad "submission: the API cannot log in with SMTP_URL: $(tail -n 1 <<<"$res")"
  fi
  if timeout 5 bash -c 'exec 3<>/dev/tcp/gmail-smtp-in.l.google.com/25' 2>/dev/null; then
    hint "outbound port 25 is open (gmail-smtp-in.l.google.com answers)"
  else
    hint "outbound port 25 seems blocked: mail to other servers stays queued; ask your hoster to open it"
  fi
}

# Joins the strings of each TXT record dig prints into one value per line.
txt_join() { sed -e 's/" "//g' -e 's/^"//' -e 's/"$//'; }

# Compares each record of dns_records with what the resolver answers.
check_dns() {
  local name type prio value got want mh=${CUR[RAKAZO_HOST]:-}
  printf '\nDNS\n'
  if ! command -v dig >/dev/null; then
    hint "dig is not installed (dnsutils or bind-utils): the records are not compared"
    return 0
  fi
  detect_ips
  while IFS='|' read -r name type prio value; do
    case $type in
      A | AAAA)
        want='^[0-9.]+$'
        [[ $type == A ]] || want='^[0-9a-fA-F:]*:[0-9a-fA-F:]*$'
        got=$(dig +short "$type" "$name" 2>/dev/null | grep -E "$want" | sort | paste -sd ' ' - || true)
        if [[ -z $got ]]; then bad "$type $name: no record"
        elif [[ $value == \<* || " $got " == *" $value "* ]]; then ok "$type $name → $got"
        else hint "$type $name → $got, not this host's $value (fine only behind a proxy or CDN)"; fi
        ;;
      MX)
        got=$(dig +short MX "$name" 2>/dev/null | awk '{print tolower($2)}' | sed 's/\.$//' || true)
        if grep -qxF "$value" <<<"$got"; then ok "MX $name → $value"
        else bad "MX $name → ${got:-none}, expected $prio $value"; fi
        ;;
      TXT)
        want=${value%%[; ]*}
        got=$(dig +short TXT "$name" 2>/dev/null | txt_join | grep -F "$want" || true)
        if [[ -z $got ]]; then bad "TXT $name: no $want record"
        elif (($(wc -l <<<"$got") > 1)); then bad "TXT $name: more than one $want record"
        elif [[ ${got//[[:space:]]/} == "${value//[[:space:]]/}" ]]; then ok "TXT $name: $want as expected"
        elif [[ $want == v=DKIM1 ]]; then bad "TXT $name: another key than postfix/dkim/rakazo.private"
        elif [[ $want == v=spf1 && ($got == *"$mh"* || (-n $IPV4 && $got == *"$IPV4"*)) ]]; then
          ok "TXT $name: SPF includes this host ($got)"
        elif [[ $want == v=spf1 ]]; then bad "TXT $name: SPF \"$got\" does not allow $mh"
        else hint "TXT $name is \"$got\", suggested \"$value\""; fi
        ;;
    esac
  done < <(dns_records CUR "$OLD_MAIL")
  if [[ $OLD_MAIL == *send && -n $IPV4 ]]; then
    got=$(dig +short -x "$IPV4" 2>/dev/null | sed 's/\.$//' | head -n 1 || true)
    if [[ $got == "$mh" ]]; then ok "PTR $IPV4 → $mh"
    else bad "PTR $IPV4 → ${got:-none}, expected $mh (set it at your hoster)"; fi
  fi
}

check() {
  local k v host origin code res pw app_pw e running="" web api up img cap key_env
  [[ -f $ENV_FILE ]] || die "No .env found. Run $SELF first."
  load_env
  load_postfix_env
  host=${CUR[RAKAZO_HOST]:-}
  origin=https://$host
  up=$(upstream_ip "${CUR[RAKAZO_BIND]:-127.0.0.1}")
  web=$up:${CUR[RAKAZO_WEB_PORT]:-}
  api=$up:${CUR[RAKAZO_API_PORT]:-}

  check_deploy
  printf '\n.env\n'
  [[ $(stat -c %a "$ENV_FILE" 2>/dev/null || echo 600) == 600 ]] ||
    hint ".env is not mode 600: chmod 600 .env"
  for k in RAKAZO_HOST WEB_ORIGIN BETTER_AUTH_URL API_URL RAKAZO_BIND RAKAZO_WEB_PORT RAKAZO_API_PORT \
    RAKAZO_IMAGE_TAG POSTGRES_PASSWORD DATABASE_URL DATABASE_MIGRATION_URL "${SECRET_KEYS[@]}"; do
    [[ -n ${CUR[$k]:-} ]] || bad "$k is missing or empty"
  done
  case ${CUR[RAKAZO_BIND]:-} in
    "" | 127.0.0.1) ;;
    0.0.0.0) hint "RAKAZO_BIND=0.0.0.0: web and API answer on every network without TLS, past ufw" ;;
    *)
      if ! valid_ipv4 "${CUR[RAKAZO_BIND]}"; then bad "RAKAZO_BIND \"${CUR[RAKAZO_BIND]}\" is not an IPv4 address"
      elif command -v ip >/dev/null && ! ip -4 -o addr show | grep -qF " ${CUR[RAKAZO_BIND]}/"; then
        bad "RAKAZO_BIND ${CUR[RAKAZO_BIND]} is no address of this host: the stack cannot publish its ports"
      else hint "RAKAZO_BIND=${CUR[RAKAZO_BIND]}: web and API answer there without TLS, past ufw"; fi
      ;;
  esac
  if [[ ${CUR[RAKAZO_BIND]:-127.0.0.1} != 127.0.0.1 && -z ${CUR[TRUSTED_PROXIES]:-} ]]; then
    hint "a reverse proxy on another machine needs TRUSTED_PROXIES, otherwise all users share one sign-in rate limit"
  fi
  for k in RAKAZO_WEB_PORT RAKAZO_API_PORT; do
    [[ -z ${CUR[$k]:-} ]] || valid_port "${CUR[$k]}" || bad "$k \"${CUR[$k]}\" is not a port"
  done
  [[ -z ${CUR[RAKAZO_WEB_PORT]:-} || $web != "$api" ]] || bad "RAKAZO_WEB_PORT and RAKAZO_API_PORT are the same"
  valid_host "$host" || bad "RAKAZO_HOST \"$host\" is not a public hostname"
  for k in WEB_ORIGIN BETTER_AUTH_URL API_URL; do
    v=${CUR[$k]:-}
    if [[ $v == "$origin" ]]; then ok "$k = $origin"
    else bad "$k is \"$v\", expected exactly $origin (scheme, no trailing slash, no port)"; fi
  done

  for k in "${SECRET_KEYS[@]}"; do
    v=${CUR[$k]:-}
    [[ -z $v ]] && continue
    ((${#v} >= 32)) || bad "$k is shorter than 32 characters"
    for e in "${SECRET_KEYS[@]}"; do
      [[ $e != "$k" && $v == "${CUR[$e]:-}" ]] && bad "$k and $e have the same value"
    done
  done

  pw=${CUR[POSTGRES_PASSWORD]:-}
  if [[ ${CUR[DATABASE_MIGRATION_URL]:-} =~ ^postgres://rakazo:([^@]+)@postgres:5432/rakazo$ ]]; then
    [[ ${BASH_REMATCH[1]} == "$pw" ]] && ok "DATABASE_MIGRATION_URL matches POSTGRES_PASSWORD" ||
      bad "DATABASE_MIGRATION_URL contains a different password than POSTGRES_PASSWORD"
  else
    bad "DATABASE_MIGRATION_URL is not of the form postgres://rakazo:<password>@postgres:5432/rakazo"
  fi
  if [[ ${CUR[DATABASE_URL]:-} =~ ^postgres://rakazo_app:([^@]+)@postgres:5432/rakazo$ ]]; then
    app_pw=${BASH_REMATCH[1]}
    [[ $app_pw != "$pw" ]] && ok "DATABASE_URL uses its own login rakazo_app" ||
      bad "rakazo_app and the owner have the same password"
  else
    bad "DATABASE_URL is not of the form postgres://rakazo_app:<password>@postgres:5432/rakazo"
  fi

  if [[ -n ${CUR[SIGNUP_ALLOWLIST]:-} && ${CUR[SIGNUPS_ENABLED]:-} != false &&
    -z ${CUR[EMAIL_PROVIDER]:-}${CUR[SMTP_URL]:-} ]]; then
    if [[ ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} == true ]]; then
      hint "SSO sign-up skips SIGNUP_ALLOWLIST (OIDC_ALLOW_SIGNUP_BYPASS): restrict users at the provider"
    elif [[ -n ${CUR[OIDC_ISSUER]:-} ]]; then
      hint "SIGNUP_ALLOWLIST without email delivery: only SSO sign-up works (provider must send email_verified=true)"
    else
      bad "SIGNUP_ALLOWLIST is set but there is no email delivery or SSO: nobody can sign up"
    fi
  fi
  if [[ ${CUR[SIGNUPS_ENABLED]:-} == false && -n ${CUR[SIGNUP_ALLOWLIST]:-} ]]; then
    hint "SIGNUP_ALLOWLIST has no effect while SIGNUPS_ENABLED=false; to admit only these addresses set SIGNUPS_ENABLED=true"
  fi
  if [[ ${CUR[SIGNUPS_ENABLED]:-} == false && -n ${CUR[OIDC_ISSUER]:-} ]]; then
    if [[ ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} == true ]]; then
      bad "signup is closed and the SSO provider sends no email_verified: SSO cannot be used (no sign-up, no Link SSO)"
    else
      hint "signup is closed, so SSO cannot create accounts: ./generate-env.sh --owner, then Link SSO in the account settings"
    fi
  fi
  case ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} in
    "" | true | false) ;;
    *) bad "OIDC_ALLOW_SIGNUP_BYPASS must be true or false (the API does not start otherwise)" ;;
  esac
  if is_entra "${CUR[OIDC_ISSUER]:-}"; then
    valid_entra_issuer "${CUR[OIDC_ISSUER]}" ||
      bad "OIDC_ISSUER for Entra ID must be https://login.microsoftonline.com/<tenant ID>/v2.0"
    [[ ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} == true ]] ||
      bad "Entra ID sends no email_verified: SSO fails with EMAIL_VERIFICATION_REQUIRED; set OIDC_ALLOW_SIGNUP_BYPASS=true (./generate-env.sh)"
  fi
  if [[ -n ${CUR[OIDC_ISSUER]:-}${CUR[OIDC_CLIENT_ID]:-}${CUR[OIDC_CLIENT_SECRET]:-} ]]; then
    [[ -n ${CUR[OIDC_ISSUER]:-} && -n ${CUR[OIDC_CLIENT_ID]:-} && -n ${CUR[OIDC_CLIENT_SECRET]:-} ]] ||
      bad "set OIDC_ISSUER, OIDC_CLIENT_ID and OIDC_CLIENT_SECRET together (the API does not start otherwise)"
    [[ ${CUR[OIDC_ISSUER]:-} == https://* ]] || bad "OIDC_ISSUER must start with https://"
  fi
  if [[ -n ${CUR[PIPEDREAM_CLIENT_ID]:-}${CUR[PIPEDREAM_CLIENT_SECRET]:-}${CUR[PIPEDREAM_PROJECT_ID]:-} ]]; then
    [[ -n ${CUR[PIPEDREAM_CLIENT_ID]:-} && -n ${CUR[PIPEDREAM_CLIENT_SECRET]:-} && -n ${CUR[PIPEDREAM_PROJECT_ID]:-} ]] ||
      bad "set PIPEDREAM_CLIENT_ID, PIPEDREAM_CLIENT_SECRET and PIPEDREAM_PROJECT_ID together"
    [[ ${CUR[PIPEDREAM_ENVIRONMENT]:-} == production ]] ||
      hint "PIPEDREAM_ENVIRONMENT is not production: Rakazo uses Pipedream's development environment"
  fi
  case ${CUR[RAKAZO_IMAGE_TAG]:-} in
    "" | latest) ;;
    edge) hint "images on edge: the development state of main, untested" ;;
    *) [[ ${CUR[RAKAZO_IMAGE_TAG]} =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] ||
         bad "RAKAZO_IMAGE_TAG \"${CUR[RAKAZO_IMAGE_TAG]}\" is not a valid image tag" ;;
  esac
  if [[ ${CUR[RAKAZO_IMAGE_TAG]:-} != edge ]]; then
    for k in "${EDGE_KEYS[@]}"; do
      if [[ -n ${CUR[$k]:-} ]]; then hint "$k needs edge or a release after v0.8.0; older images ignore it"; fi
    done
  fi
  v=${CUR[SCIM_BEARER_TOKEN]:-}
  if [[ -n $v ]]; then
    ((${#v} >= 32)) && [[ $v != *[[:space:]]* ]] ||
      bad "SCIM_BEARER_TOKEN needs at least 32 characters without spaces (the API does not start otherwise)"
    if [[ -z ${CUR[EMAIL_PROVIDER]:-}${CUR[SMTP_URL]:-} &&
      (-z ${CUR[OIDC_ISSUER]:-} || ${CUR[OIDC_ALLOW_SIGNUP_BYPASS]:-} == true) ]]; then
      bad "accounts from SCIM cannot sign in: no email delivery for codes and no SSO with email_verified"
    fi
  fi
  if [[ -n ${CUR[INBOUND_EMAIL_DOMAIN]:-}${CUR[INBOUND_EMAIL_SECRET]:-} ]]; then
    if [[ -z ${CUR[INBOUND_EMAIL_DOMAIN]:-} || -z ${CUR[INBOUND_EMAIL_SECRET]:-} ]]; then
      bad "set INBOUND_EMAIL_DOMAIN and INBOUND_EMAIL_SECRET together (the API does not start otherwise)"
    else
      valid_host "${CUR[INBOUND_EMAIL_DOMAIN],,}" ||
        bad "INBOUND_EMAIL_DOMAIN \"${CUR[INBOUND_EMAIL_DOMAIN]}\" is not a domain name (the API does not start otherwise)"
      ((${#CUR[INBOUND_EMAIL_SECRET]} >= 32)) ||
        bad "INBOUND_EMAIL_SECRET is shorter than 32 characters (the API does not start otherwise)"
    fi
  fi
  if [[ ${CUR[PI_DEFAULT_PROVIDER]:-} == local ]]; then
    [[ ${CUR[PI_DEFAULT_CREDENTIALS]:-} == host ]] ||
      bad "PI_DEFAULT_PROVIDER=local needs PI_DEFAULT_CREDENTIALS=host"
    [[ -n ${CUR[PI_DEFAULT_MODEL]:-} && ,${CUR[RAKAZO_LOCAL_MODELS]:-}, == *,"${CUR[PI_DEFAULT_MODEL]:-}",* ]] ||
      bad "PI_DEFAULT_MODEL must be one of RAKAZO_LOCAL_MODELS"
    [[ ${CUR[RAKAZO_LOCAL_MODELS_URL]:-} =~ ^https?:// ]] ||
      bad "RAKAZO_LOCAL_MODELS_URL must be an http(s) URL"
  fi
  v=$(deployment_model CUR)
  if [[ $v == none* ]]; then
    hint "no deployment model: every new account has to connect its own model provider (./generate-env.sh)"
  else
    ok "deployment model: $v"
  fi
  if [[ -z ${CUR[COMPOSIO_API_KEY]:-}${CUR[PIPEDREAM_CLIENT_ID]:-} ]]; then
    hint "no app catalog (Composio/Pipedream): Integrations → Apps stays empty, own MCP/OpenAPI work"
  fi
  for k in "${DROPPED_KEYS[@]}"; do hint "$k has no effect in .env (fixed in docker-compose.yml)"; done

  printf '\nCompose\n'
  if ! command -v docker >/dev/null; then
    hint "docker not found, runtime checks skipped"
  elif ! docker compose config -q 2>/dev/null; then
    bad "docker compose config fails:"
    docker compose config -q 2>&1 | sed 's/^/          /' || true
  else
    ok "docker compose config"
    v=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)
    if [[ -z $v ]]; then hint "Docker daemon not reachable (permissions? sudo or group docker)"
    elif ((${v%%.*} >= 26)); then ok "Docker Engine $v"
    else bad "Docker Engine $v is too old, Rakazo needs 26 or newer"; fi
    running=$(docker compose ps -q --status running api 2>/dev/null || true)
    if [[ -z $running ]]; then
      hint "stack is not running, runtime checks skipped (docker compose up -d)"
    else
      while read -r k v; do
        [[ -z $k ]] && continue
        [[ $v == healthy || $v == running ]] && ok "$k: $v" || bad "$k: $v (docker compose logs $k)"
      done < <(docker compose ps --format '{{.Service}} {{if .Health}}{{.Health}}{{else}}{{.State}}{{end}}' 2>/dev/null)
    fi
  fi

  check_caddy "$web" "$api"
  check_mail "$running"

  if [[ -n $running ]]; then
    command -v curl >/dev/null || die "curl is missing for the runtime checks."
    printf '\nLocal (%s)\n' "$up"
    res=$(http_probe "http://$api/health")
    [[ ${res: -3} == 200 ]] && ok "API $api/health" || bad "API $api/health answers ${res: -3}"
    code=$(http_probe "http://$web/" -H "Host: $host")
    code=${code: -3}
    if [[ $code == 200 ]]; then ok "web $web accepts host $host"
    elif [[ $code == 403 ]]; then bad "web $web rejects host $host (RAKAZO_HOST, then docker compose up -d)"
    else bad "web $web answers $code"; fi
    check_cors "http://$api" "$origin" "API"
    check_screen "http://$web" "web" -H "Host: $host"
    res=$(curl -sS --max-time 10 "http://$api/internal/health" 2>/dev/null || true)
    v=$(sed -n 's/.*"sandbox":"\([^"]*\)".*/\1/p' <<<"$res")
    [[ $v == docker ]] && ok "API starts computers through the Docker supervisor" ||
      bad "API reports sandbox \"${v:-?}\" instead of docker (docker compose logs api)"
    [[ $res != *'"degraded":true'* ]] || bad "API reports degraded, the secret store is limited (docker compose logs api)"
    for k in composio pipedream; do
      [[ $k == composio && -n ${CUR[COMPOSIO_API_KEY]:-} || $k == pipedream && -n ${CUR[PIPEDREAM_CLIENT_ID]:-} ]] || continue
      health_has "$res" "$k" && ok "app catalog $k is active" ||
        bad "app catalog $k is set in .env, but the API does not report it active (docker compose logs api)"
    done

    if [[ ${CUR[PI_DEFAULT_PROVIDER]:-} == local ]]; then
      # Images before edge send the key "local" whatever .env holds.
      key_env=()
      [[ ${CUR[RAKAZO_IMAGE_TAG]:-} == edge ]] || key_env=(-e RAKAZO_LOCAL_MODELS_API_KEY=)
      if docker compose exec -T "${key_env[@]}" api node -e "$LOCAL_MODELS_JS" >/dev/null 2>&1; then
        ok "API reaches the model server ${CUR[RAKAZO_LOCAL_MODELS_URL]:-}"
      else
        bad "API cannot list ${CUR[RAKAZO_LOCAL_MODELS_URL]:-}/models (address from inside a container? server bound to 127.0.0.1 only?)"
      fi
    fi
    [[ -z ${CUR[SCIM_BEARER_TOKEN]:-} ]] || check_scim "http://$api" "API"
    [[ -z ${CUR[INBOUND_EMAIL_DOMAIN]:-} || -z ${CUR[INBOUND_EMAIL_SECRET]:-} ]] || check_inbound "http://$api" "API"

    printf '\nAccounts\n'
    split_list "${CUR[RAKAZO_ADMIN_EMAILS]:-}"
    for e in "${LIST[@]}"; do
      if ! v=$(printf '%s\n' "SELECT \"emailVerified\" FROM \"user\" WHERE email = :'email';" |
        docker compose exec -T postgres psql -U rakazo -d rakazo -tAq -v email="$e" 2>/dev/null); then
        hint "accounts not readable from the database (docker compose logs postgres)"
        break
      fi
      case $v in
        t) ok "admin $e has a verified account" ;;
        f) bad "admin $e is not verified, so no admin rights: ./generate-env.sh --owner with its password" ;;
        *) [[ ${CUR[SIGNUPS_ENABLED]:-} == false ]] &&
             bad "no account for admin $e yet: ./generate-env.sh --owner" ||
             hint "no account for admin $e yet: ./generate-env.sh --owner" ;;
      esac
    done
    if ((${#LIST[@]} == 0)); then
      v=$(docker compose exec -T postgres psql -U rakazo -d rakazo -tAqc 'SELECT count(*) FROM "user"' 2>/dev/null || true)
      [[ $v == 0 ]] && hint "no accounts yet: ./generate-env.sh --owner" || hint "no RAKAZO_ADMIN_EMAILS set"
    fi

    printf '\nComputers\n'
    if docker compose exec -T supervisor node -e "$DOCKER_PING_JS" >/dev/null 2>&1; then
      ok "supervisor reaches Docker through /var/run/docker.sock"
    else
      bad "supervisor cannot reach Docker (rootless Docker or another socket path? docker compose logs supervisor)"
    fi
    img=$(docker compose exec -T supervisor printenv RAKAZO_COMPUTER_IMAGE 2>/dev/null || true)
    img=${img//$'\r'/}
    if [[ -n $img ]] && docker image inspect "$img" >/dev/null 2>&1; then
      ok "computer image $img is present"
    else
      hint "computer image ${img:-?} is missing locally, the first computer pulls it (slow). Ahead of time: docker compose pull computer"
    fi
    res=$(docker compose logs --no-log-prefix supervisor 2>/dev/null || true)
    if systemctl is-enabled rakazo-computer-egress.service >/dev/null 2>&1; then
      if [[ $res == *"computer egress is open"* ]]; then
        bad "egress rules are installed, but the supervisor uses open egress: docker compose up -d --force-recreate supervisor"
      else
        ok "egress rules installed: computers reach neither the host nor the LAN nor cloud metadata"
      fi
    else
      hint "computers have open network access (host, LAN, 169.254.169.254). Recommended: restrict-computer-egress.sh,"
      hint "the commands are printed at the end of ./generate-env.sh."
    fi
    k=$(docker ps -q --filter label=rakazo.managed=true 2>/dev/null | wc -l || true)
    v=$(docker network ls -q --filter label=rakazo.botId 2>/dev/null | wc -l || true)
    ok "$k computers running, $v computer networks created"
    cap=$(pool_capacity)
    e=$(docker network ls -q --filter driver=bridge 2>/dev/null | wc -l || true)
    if [[ -z $cap ]]; then
      hint "Docker's built-in address pools hold about 30 networks and every computer needs one ($e in use)."
      hint "For more computers set default-address-pools (step 3 of ./generate-env.sh)."
    elif ((e * 10 >= cap * 8)); then
      bad "Docker address pools nearly full: $e of $cap networks; extend default-address-pools"
    else
      ok "Docker address pools: $e of $cap networks in use"
    fi

    printf '\nPublic (%s)\n' "$origin"
    if ! getent hosts "$host" >/dev/null; then
      bad "$host does not resolve (DNS record missing or not propagated yet)"
    else
      ok "DNS: $host → $(getent hosts "$host" | awk '{print $1}' | sort -u | tr '\n' ' ')"
      res=$(http_probe "$origin/health")
      code=${res: -3}
      if [[ $code == 200 ]]; then
        ok "$origin/health through Caddy"
        grep -qi '^strict-transport-security:' <<<"$res" && ok "HSTS set" ||
          hint "no Strict-Transport-Security header (using Caddyfile.example?)"
        code=$(http_probe "$origin/")
        [[ ${code: -3} == 200 ]] && ok "$origin/ (web)" || bad "$origin/ answers ${code: -3}"
        check_cors "$origin" "$origin" "Caddy"
        check_screen "$origin" "Caddy"
        [[ -z ${CUR[SCIM_BEARER_TOKEN]:-} ]] || check_scim "$origin" "Caddy"
        [[ -z ${CUR[INBOUND_EMAIL_DOMAIN]:-} || -z ${CUR[INBOUND_EMAIL_SECRET]:-} ]] ||
          check_inbound "$origin" "Caddy"
      elif [[ $code == 000 ]]; then
        bad "$origin not reachable (Caddy running? certificate? ports 80/443 open? sudo journalctl -u caddy)"
      else
        bad "$origin/health answers $code (Caddy block, upstreams on 127.0.0.1?)"
      fi
    fi
  fi
  check_dns

  printf '\n'
  if ((ERRORS)); then
    printf '%d problem(s) found.\n' "$ERRORS"
    printf 'Diagnostics report without secrets, e.g. for an issue: docker compose exec api node dist/cli/diagnostics.js\n'
    exit 1
  fi
  printf 'All good.\n'
}

usage() { sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

ACTION="" ACCOUNT=""
while (($#)); do
  case $1 in
    --dir) (($# > 1)) || die "--dir needs a directory."; DEPLOY_DIR=$2; shift ;;
    --dir=*) DEPLOY_DIR=${1#*=} ;;
    --owner | --check | -h | --help) ACTION=$1 ;;
    --deactivate | --reactivate) ACTION=$1 ACCOUNT=${2-}; (($# == 1)) || shift ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
  shift
done
[[ -n $DEPLOY_DIR ]] || die "--dir needs a directory."
DEPLOY_DIR=$(realpath -m -- "$DEPLOY_DIR")
[[ $DEPLOY_DIR == /opt/rakazo ]] || DIR_OPT=" --dir $DEPLOY_DIR"
# How to call this script again, as printed in hints and next steps.
SELF=${REPO_DIR/#"${HOME:-/nonexistent}"/\~}/generate-env.sh$DIR_OPT

case $ACTION in
  "") generate ;;
  --owner) use_deploy_dir; owner ;;
  --check) use_deploy_dir; check ;;
  --deactivate) use_deploy_dir; account_status deactivate "$ACCOUNT" ;;
  --reactivate) use_deploy_dir; account_status reactivate "$ACCOUNT" ;;
  -h | --help) usage ;;
esac
