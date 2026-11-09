#!/usr/bin/env bash
# Rakazo – writes the .env for docker-compose.yml.
#
#   ./generate-env.sh           Create or update .env interactively. Existing secrets and custom
#                               entries are kept, the previous file is backed up.
#   ./generate-env.sh --owner   Create the admin account with a password (stack must be running)
#   ./generate-env.sh --check   Check .env; with the stack running also health, host check,
#                               accounts, computers, screen proxy, Caddy, TLS and CORS
#
# .env holds secrets, domain, ports and options. Everything else is fixed in docker-compose.yml
# and takes precedence there.

set -euo pipefail
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))) ||
  { echo "Error: Bash 4.4 or newer required." >&2; exit 1; }
cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=.env
DEFAULT_WEB_PORT=5173
DEFAULT_API_PORT=3100
CADDY_EXAMPLE_URL=https://github.com/nicolaeser/Rakazo-Setup/blob/main/Caddyfile.example
CADDY_EXAMPLE_RAW=https://raw.githubusercontent.com/nicolaeser/Rakazo-Setup/main/Caddyfile.example

# Managed by this script.
MANAGED_KEYS=(
  RAKAZO_HOST WEB_ORIGIN BETTER_AUTH_URL API_URL
  RAKAZO_WEB_PORT RAKAZO_API_PORT SANDBOX_IDLE_MS
  POSTGRES_PASSWORD DATABASE_URL DATABASE_MIGRATION_URL
  BETTER_AUTH_SECRET ENCRYPTION_KEY SCREEN_PROXY_SECRET SANDBOX_SUPERVISOR_TOKEN
  SIGNUPS_ENABLED SIGNUP_ALLOWLIST RAKAZO_ADMIN_EMAILS
  EMAIL_PROVIDER EMAIL_API_KEY SMTP_URL EMAIL_FROM
  OIDC_ISSUER OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_NAME OIDC_ALLOW_SIGNUP_BYPASS
  COMPOSIO_API_KEY PIPEDREAM_CLIENT_ID PIPEDREAM_CLIENT_SECRET PIPEDREAM_PROJECT_ID PIPEDREAM_ENVIRONMENT
  OPENROUTER_API_KEY
)
# No effect in .env: fixed in docker-compose.yml or left over from the upstream setup.
FIXED_KEYS=(
  NODE_ENV DATA_DIR WAKEUP_DRIVER AGENT_RUNTIME SANDBOX_PROVIDER SANDBOX_SUPERVISOR_URL
  CONTENT_ENCRYPTION MAX_UPLOAD_SIZE_MB API_HOST API_PORT POSTGRES_USER POSTGRES_DB
  POSTGRES_APP_PASSWORD COMPOSE_PROFILES RAKAZO_DATA_DIR RAKAZO_CREDENTIALS_DIR
  RAKAZO_IMAGE RAKAZO_IMAGE_TAG RAKAZO_COMPUTER_IMAGE RAKAZO_COMPUTER_IMAGE_TAG
  POSTGRES_IMAGE BUSYBOX_IMAGE CADDY_IMAGE CADDYFILE_PATH CADDY_HTTP_PORT CADDY_HTTPS_PORT
  RAKAZO_WEB_BIND DOCKER_SOCKET_PATH
)
SECRET_KEYS=(BETTER_AUTH_SECRET ENCRYPTION_KEY SCREEN_PROXY_SECRET SANDBOX_SUPERVISOR_TOKEN)

declare -A CUR=()  # values from the existing .env
declare -A NEW=()  # values to write
CUSTOM_LINES=()    # custom entries, copied unchanged
DROPPED_KEYS=()
PORTS_CHANGED=0

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
  [[ $(docker compose port "$2" "$3" 2>/dev/null) != "127.0.0.1:$1" ]]
}

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

keep_or_new() { if [[ -n $1 ]]; then printf '%s' "$1"; else openssl rand -hex "$2"; fi; }

step_domain() {
  local domain old=${CUR[RAKAZO_HOST]:-}
  printf '\n== Domain ==\n'
  printf 'Caddy on the host terminates TLS and forwards to 127.0.0.1. All origins are derived from\n'
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
  local web api old_web=${CUR[RAKAZO_WEB_PORT]:-} old_api=${CUR[RAKAZO_API_PORT]:-}
  printf '\n== Ports ==\n'
  printf 'Web and API listen on 127.0.0.1 only; Caddy on the host forwards to them.\n'
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

step_computers() {
  local def=y
  printf '\n== Computers ==\n'
  printf 'Every bot gets its own Docker container with a desktop and browser (up to 2 GB RAM, 2 CPUs each).\n'
  printf 'By default Rakazo stops it after 10 minutes idle. For Docker the docs recommend keeping it\n'
  printf 'running so started apps and sessions stay open. That costs RAM, and every running computer\n'
  printf 'holds its own Docker network (the default address pools allow a few dozen).\n'
  [[ -v CUR[SANDBOX_IDLE_MS] && ${CUR[SANDBOX_IDLE_MS]} != 0 ]] && def=n
  NEW[SANDBOX_IDLE_MS]=0
  ask_yn "Keep computers running when idle" "$def" && return
  NEW[SANDBOX_IDLE_MS]=""
  if [[ ${CUR[SANDBOX_IDLE_MS]:-0} != 0 ]]; then NEW[SANDBOX_IDLE_MS]=${CUR[SANDBOX_IDLE_MS]}; fi
}

step_email() {
  local mode def=1 key from smtp
  printf '\n== Email ==\n'
  printf 'For verification mails, password resets and sign-in codes. Without email there is no\n'
  printf 'password recovery, and an allowlist only works with SSO.\n'
  if [[ ${CUR[EMAIL_PROVIDER]:-} == resend ]]; then def=2
  elif [[ -n ${CUR[SMTP_URL]:-} || ${CUR[EMAIL_PROVIDER]:-} == smtp ]]; then def=3; fi
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
      ask_secret smtp "SMTP_URL" "${CUR[SMTP_URL]:-}"
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

step_signups() {
  local mode def list e entries=() first example=@company.com
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
      "closed – nobody can sign up, not even with SSO; accounts only via --owner" \
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

step_models() {
  local key
  printf '\n== Models (optional) ==\n'
  printf 'Models can also be connected in the app after signing in.\n'
  ask_secret key "OpenRouter API key (empty = none)" "${CUR[OPENROUTER_API_KEY]:-}"
  NEW[OPENROUTER_API_KEY]=$key
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
  local tmp backup line
  tmp=$(mktemp "$ENV_FILE.XXXXXX")
  {
    printf '# Rakazo – written by generate-env.sh on %s. Contains secrets: do not commit or share.\n' "$(date '+%Y-%m-%d %H:%M')"
    printf '# To change: run ./generate-env.sh again. Then: docker compose up -d\n'
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
# Published on 127.0.0.1 only; Caddy forwards to them. After a change update the ports in
# /etc/caddy/rakazo.caddy, reload Caddy and run docker compose up -d.
EOF
    env_line RAKAZO_WEB_PORT
    env_line RAKAZO_API_PORT
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
    printf '\n# --- Email (optional) ----------------------------------------------------------------------------\n'
    env_line EMAIL_PROVIDER
    env_line EMAIL_API_KEY
    env_line SMTP_URL
    env_line EMAIL_FROM
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
    printf '\n# --- Models (optional) ----------------------------------------------------------------------------\n'
    env_line OPENROUTER_API_KEY
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
    backup=$ENV_FILE.bak.$(date +%Y%m%d-%H%M%S)
    cp -p "$ENV_FILE" "$backup"
    chmod 600 "$backup"
    printf '\nPrevious .env backed up as %s\n' "$backup"
  fi
  mv "$tmp" "$ENV_FILE"
}

generate() {
  local k caddy_note caddy_sed cap
  command -v openssl >/dev/null || die "openssl is missing."
  [[ -t 0 ]] || die "Please run interactively in a terminal."
  load_env
  if pg_data_exists && [[ -z ${CUR[POSTGRES_PASSWORD]:-} || -z ${CUR[ENCRYPTION_KEY]:-} ]]; then
    die "./data/postgres already holds a database, but .env lacks POSTGRES_PASSWORD or ENCRYPTION_KEY.
New values would not match (sign-in fails, stored credentials become unreadable). Restore the old
.env from its backup or delete ./data deliberately."
  fi

  printf 'Rakazo – set up .env\n'
  if [[ -f $ENV_FILE ]]; then
    printf 'Existing .env found: values in [ ] are the current ones, secrets are kept.\n'
  fi
  printf 'Enter keeps the value in [ ], "-" clears a field.\n'

  step_domain
  step_ports
  step_computers
  step_email
  step_sso
  step_admins
  step_signups
  step_catalog
  step_models
  step_secrets
  write_env
  mkdir -p data/postgres data/app data/web-assets credentials

  printf '\n.env written (mode 600).\n'
  for k in "${DROPPED_KEYS[@]}"; do
    printf '  removed: %s (fixed in docker-compose.yml or no longer needed)\n' "$k"
  done
  printf '\n  Domain:        https://%s\n' "${NEW[RAKAZO_HOST]}"
  printf '  Computers:     %s\n' "$([[ ${NEW[SANDBOX_IDLE_MS]} == 0 ]] && echo 'keep running when idle' || echo 'stop when idle')"
  printf '  Email:         %s\n' "${NEW[EMAIL_PROVIDER]:-none}"
  printf '  Signup:        %s\n' "$(case $SIGNUP_MODE in 1) echo closed ;; 2) echo "allowlist (${NEW[SIGNUP_ALLOWLIST]})" ;; 3) echo open ;; esac)"
  printf '  Ports:         web 127.0.0.1:%s, API 127.0.0.1:%s\n' "${NEW[RAKAZO_WEB_PORT]}" "${NEW[RAKAZO_API_PORT]}"
  printf '  SSO:           %s\n' "${NEW[OIDC_ISSUER]:-off}"
  printf '  App catalog:   %s\n' "$(case $CATALOG_MODE in 1) echo none ;; 2) echo Composio ;; 3) echo "Pipedream (${NEW[PIPEDREAM_ENVIRONMENT]})" ;; esac)"
  caddy_note=. caddy_sed="-e 's/rakazo\\.example\\.com/${NEW[RAKAZO_HOST]}/'"
  if [[ ${NEW[RAKAZO_WEB_PORT]} != "$DEFAULT_WEB_PORT" || ${NEW[RAKAZO_API_PORT]} != "$DEFAULT_API_PORT" ]]; then
    caddy_note=",
     the web port $DEFAULT_WEB_PORT with ${NEW[RAKAZO_WEB_PORT]} and the API port $DEFAULT_API_PORT with ${NEW[RAKAZO_API_PORT]}."
    caddy_sed+=" -e 's/127\\.0\\.0\\.1:$DEFAULT_WEB_PORT /127.0.0.1:${NEW[RAKAZO_WEB_PORT]} /'"
    caddy_sed+=" -e 's/127\\.0\\.0\\.1:$DEFAULT_API_PORT /127.0.0.1:${NEW[RAKAZO_API_PORT]} /'"
  fi
  if ((PORTS_CHANGED)); then
    warn "Ports changed: update the ports in /etc/caddy/rakazo.caddy and reload Caddy, otherwise the domain answers 502."
  fi

  cat <<EOF

Next steps
  1. DNS: A/AAAA record for ${NEW[RAKAZO_HOST]} pointing to this host.
     Ports 80/tcp and 443/tcp open (443/udp for HTTP/3).
  2. Caddy on the host: get Caddyfile.example from GitHub, save it as /etc/caddy/rakazo.caddy
     and replace rakazo.example.com with ${NEW[RAKAZO_HOST]}${caddy_note}
       ${CADDY_EXAMPLE_URL}
       sudo curl -fsSLo /etc/caddy/rakazo.caddy ${CADDY_EXAMPLE_RAW}
       sudo sed -i ${caddy_sed} /etc/caddy/rakazo.caddy
       once in /etc/caddy/Caddyfile:  import /etc/caddy/rakazo.caddy
       sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy
EOF
  cap=$(pool_capacity)
  if [[ -n $cap ]]; then
    printf '  3. Docker address pools are configured: room for %s networks.\n' "$cap"
  else
    cat <<'EOF'
  3. Recommended, once per host, for more than about 20 computers: every Private bot and every
     space gets its own computer with its own Docker network, and Docker's built-in address pools
     hold only about 30 networks. In /etc/docker/daemon.json (if the file exists add only the key;
     the range must not overlap your LAN, VPN or cloud network, see ip route):
       { "default-address-pools": [{ "base": "10.200.0.0/16", "size": 24 }] }
       sudo dockerd --validate --config-file /etc/docker/daemon.json && sudo systemctl restart docker
EOF
  fi
  cat <<EOF
  4. Recommended, once per host: keep computers away from the host, the LAN and cloud metadata
     (169.254.169.254). Without these firewall rules computers have open network access. Linux with
     Docker Engine and iptables; read the script first:
       curl -fsSLo /tmp/restrict-computer-egress.sh \\
         https://raw.githubusercontent.com/elie222/rakazo/main/infra/compose/restrict-computer-egress.sh
       sudo bash /tmp/restrict-computer-egress.sh
     If the stack is already running: docker compose up -d --force-recreate supervisor
  5. Start the stack:  docker compose up -d
  6. Check:            ./generate-env.sh --check
EOF
  if ((SIGNUP_MODE == 1)); then
    printf '  7. Create the first account with a password, the only way in while signup is closed:\n'
  else
    printf '  7. Create the admin account with a password:\n'
  fi
  printf '       ./generate-env.sh --owner\n'
  if [[ -n ${NEW[OIDC_ISSUER]} ]]; then
    printf '\nSSO: redirect URI at the provider: https://%s/api/auth/callback/oidc\n' "${NEW[RAKAZO_HOST]}"
    printf 'The ID token needs the email claim (Entra ID: Token configuration → optional claim email).\n'
    if [[ -n ${NEW[OIDC_ALLOW_SIGNUP_BYPASS]} ]]; then
      printf 'Without email_verified everyone the provider lets in can sign up with SSO; restrict it there\n'
      printf '(Entra ID: Enterprise application → Properties → Assignment required = Yes, assign users).\n'
      printf 'SSO accounts stay unverified: no admin rights from RAKAZO_ADMIN_EMAILS. The --owner account\n'
      printf 'cannot be linked to SSO and keeps signing in with its password.\n'
    else
      printf 'The provider must send email_verified=true. An account from --owner signs in with its\n'
      printf 'password first and then chooses Link SSO in the account settings; SSO sign-in with the same\n'
      printf 'address is refused until then.\n'
      case $SIGNUP_MODE in
        1) printf 'Signup is closed, so SSO cannot create new accounts.\n' ;;
        2) printf 'Addresses on the allowlist (%s) can create their account with SSO directly.\n' "${NEW[SIGNUP_ALLOWLIST]}" ;;
      esac
    fi
  fi
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

# --- Check ---------------------------------------------------------------------------------------

ERRORS=0
ok()   { printf '  ok      %s\n' "$*"; }
bad()  { printf '  ERROR   %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
hint() { printf '  note    %s\n' "$*"; }

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

check() {
  local k v host origin code res pw app_pw e running web api caddy_file img cap
  [[ -f $ENV_FILE ]] || die "No .env found. Run ./generate-env.sh first."
  load_env
  host=${CUR[RAKAZO_HOST]:-}
  origin=https://$host
  web=127.0.0.1:${CUR[RAKAZO_WEB_PORT]:-}
  api=127.0.0.1:${CUR[RAKAZO_API_PORT]:-}

  printf '.env\n'
  [[ $(stat -c %a "$ENV_FILE" 2>/dev/null || echo 600) == 600 ]] ||
    hint ".env is not mode 600: chmod 600 .env"
  for k in RAKAZO_HOST WEB_ORIGIN BETTER_AUTH_URL API_URL RAKAZO_WEB_PORT RAKAZO_API_PORT \
    POSTGRES_PASSWORD DATABASE_URL DATABASE_MIGRATION_URL "${SECRET_KEYS[@]}"; do
    [[ -n ${CUR[$k]:-} ]] || bad "$k is missing or empty"
  done
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

  if [[ -n ${running:-} ]]; then
    command -v curl >/dev/null || die "curl is missing for the runtime checks."
    printf '\nLocal (127.0.0.1)\n'
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

    printf '\nCaddy\n'
    caddy_file=/etc/caddy/rakazo.caddy
    if [[ ! -r $caddy_file ]]; then
      hint "$caddy_file not found: get Caddyfile.example from $CADDY_EXAMPLE_URL"
    elif grep -qF rakazo.example.com "$caddy_file"; then
      bad "$caddy_file still contains rakazo.example.com: replace it with $host, reload Caddy"
    elif ! grep -qF "$host {" "$caddy_file"; then
      bad "$caddy_file has no site block for $host: replace the domain there, reload Caddy"
    elif grep -q "reverse_proxy $web " "$caddy_file" && grep -q "reverse_proxy $api " "$caddy_file"; then
      ok "$caddy_file serves $host and points to $web and $api"
    else
      bad "$caddy_file does not point to $web/$api: fix the reverse_proxy ports there, reload Caddy"
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
      elif [[ $code == 000 ]]; then
        bad "$origin not reachable (Caddy running? certificate? ports 80/443 open? sudo journalctl -u caddy)"
      else
        bad "$origin/health answers $code (Caddy block, upstreams on 127.0.0.1?)"
      fi
    fi
  fi

  printf '\n'
  if ((ERRORS)); then
    printf '%d problem(s) found.\n' "$ERRORS"
    printf 'Diagnostics report without secrets, e.g. for an issue: docker compose exec api node dist/cli/diagnostics.js\n'
    exit 1
  fi
  printf 'All good.\n'
}

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case ${1-} in
  "") generate ;;
  --owner) owner ;;
  --check) check ;;
  -h | --help) usage ;;
  *) die "Unknown option: $1 (see --help)" ;;
esac
