#!/bin/sh

set -eu
umask 077
export LC_ALL=C

cio_die() { printf '%s\n' "comment.io: $1" >&2; exit "${2:-20}"; }

command -v curl >/dev/null 2>&1 || cio_die CURL_UNAVAILABLE 64
command -v openssl >/dev/null 2>&1 || cio_die OPENSSL_UNAVAILABLE 64

cio_host=${COMMENT_PLUGIN_HOST:?COMMENT_PLUGIN_HOST is required}
case "$cio_host" in claude-code|codex) ;; *) cio_die WRONG_HOST 64 ;; esac

cio_stat_owner() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%u' "$1" ;;
    Linux) /usr/bin/stat -c '%u' "$1" ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
}

cio_stat_mode() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%Lp' "$1" ;;
    Linux) /usr/bin/stat -c '%a' "$1" ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
}

cio_stat_links() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%l' "$1" ;;
    Linux) /usr/bin/stat -c '%h' "$1" ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
}

cio_stat_device() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%d' "$1" ;;
    Linux) /usr/bin/stat -c '%d' "$1" ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
}

cio_stat_inode() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%i' "$1" ;;
    Linux) /usr/bin/stat -c '%i' "$1" ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
}

cio_has_acl() {
  [ "$(uname -s)" = Darwin ] || return 1
  permissions=$(/bin/ls -lde "$1" 2>/dev/null | sed -n '1{s/[[:space:]].*//;p;}')
  case "$permissions" in *+*) return 0 ;; *) return 1 ;; esac
}

cio_uid=$(/usr/bin/id -u)

cio_validate_dir() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(cio_stat_owner "$1" 2>/dev/null)" = "$cio_uid" ] || return 1
  [ "$(cio_stat_mode "$1" 2>/dev/null)" = 700 ] || return 1
  ! cio_has_acl "$1" || return 1
}

cio_validate_file() {
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(cio_stat_owner "$1" 2>/dev/null)" = "$cio_uid" ] || return 1
  [ "$(cio_stat_mode "$1" 2>/dev/null)" = 600 ] || return 1
  [ "$(cio_stat_links "$1" 2>/dev/null)" = 1 ] || return 1
  ! cio_has_acl "$1" || return 1
}

cio_make_private_dir() {
  target=$1
  if [ -e "$target" ]; then cio_validate_dir "$target" || cio_die UNSAFE_STATE; return; fi
  /bin/mkdir -m 700 "$target" || cio_die STATE_CREATE_FAILED
  if [ "$(uname -s)" = Darwin ]; then /bin/chmod -N "$target" || cio_die STATE_CREATE_FAILED; fi
  cio_validate_dir "$target" || cio_die UNSAFE_STATE
}

cio_state_root() {
  case "$(uname -s)" in
    Darwin)
      anchor=$HOME/Library/Application\ Support
      if [ ! -d "$anchor" ] || [ -L "$anchor" ]; then cio_die UNSAFE_STATE; fi
      [ "$(cio_stat_owner "$anchor")" = "$cio_uid" ] || cio_die UNSAFE_STATE
      root=$anchor/Comment.io
      ;;
    Linux)
      anchor=${XDG_STATE_HOME:-$HOME/.local/state}
      if [ ! -e "$anchor" ]; then
        parent=${anchor%/*}
        if [ -z "${XDG_STATE_HOME:-}" ] && [ "$parent" = "$HOME/.local" ] && [ ! -e "$parent" ]; then
          [ -d "$HOME" ] && [ ! -L "$HOME" ] || cio_die UNSAFE_STATE
          [ "$(cio_stat_owner "$HOME")" = "$cio_uid" ] || cio_die UNSAFE_STATE
          /bin/mkdir -m 700 "$parent" || cio_die STATE_CREATE_FAILED
        fi
        if [ ! -d "$parent" ] || [ -L "$parent" ]; then cio_die UNSAFE_STATE; fi
        [ "$(cio_stat_owner "$parent")" = "$cio_uid" ] || cio_die UNSAFE_STATE
        /bin/mkdir -m 700 "$anchor" || cio_die STATE_CREATE_FAILED
      fi
      if [ ! -d "$anchor" ] || [ -L "$anchor" ]; then cio_die UNSAFE_STATE; fi
      [ "$(cio_stat_owner "$anchor")" = "$cio_uid" ] || cio_die UNSAFE_STATE
      root=$anchor/comment.io
      ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
  cio_make_private_dir "$root"
  cio_make_private_dir "$root/agent-plugins"
  printf '%s\n' "$root/agent-plugins"
}

cio_state=$(cio_state_root)

cio_hash() {
  printf '%s' "$1" | openssl dgst -sha256 | sed 's/^.*= //'
}

cio_origin() {
  value=${1%/}
  host=${value#https://}
  [ "$host" != "$value" ] || cio_die INVALID_ORIGIN 64
  case "$host" in ''|*'/'*|*'?'*|*'#'*|*'@'*|*' '*) cio_die INVALID_ORIGIN 64 ;; esac
  case "$host" in [A-Za-z0-9]*.[A-Za-z0-9]*|localhost:[0-9]*|localhost) ;; *) cio_die INVALID_ORIGIN 64 ;; esac
  printf '%s\n' "$value"
}

cio_origin_key() { cio_hash "$1"; }

cio_atomic_write() {
  target=$1
  parent=${target%/*}
  cio_validate_dir "$parent" || cio_die UNSAFE_STATE
  temporary=$parent/.write.$$.$(openssl rand -hex 8)
  ( set -C; : >"$temporary" ) 2>/dev/null || cio_die STATE_WRITE_FAILED
  /bin/chmod 600 "$temporary" || cio_die STATE_WRITE_FAILED
  if [ "$(uname -s)" = Darwin ]; then /bin/chmod -N "$temporary" || cio_die STATE_WRITE_FAILED; fi
  /bin/cat >"$temporary" || cio_die STATE_WRITE_FAILED
  [ "$(cio_stat_links "$temporary")" = 1 ] || cio_die STATE_WRITE_FAILED
  /bin/mv -f "$temporary" "$target" || cio_die STATE_WRITE_FAILED
  cio_validate_file "$target" || cio_die STATE_WRITE_FAILED
}

cio_field() {
  file=$1 key=$2
  cio_validate_file "$file" || return 1
  sed -n "s/^${key}=//p" "$file" | sed -n '1p'
}

cio_json_string() {
  key=$1 file=$2
  cio_validate_file "$file" || return 1
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | sed -n '1p'
}

cio_json_number() {
  key=$1 file=$2
  cio_validate_file "$file" || return 1
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$file" | sed -n '1p'
}

cio_json_bool() {
  key=$1 file=$2
  cio_validate_file "$file" || return 1
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\(true\|false\).*/\1/p" "$file" | sed -n '1p'
}

cio_json_first_object() {
  key=$1 file=$2
  cio_validate_file "$file" || return 1
  awk -v wanted="$key" '
    BEGIN { RS="\034" }
    {
      text=$0; marker="\"" wanted "\""; start=index(text, marker)
      if (!start) exit 1
      rest=substr(text, start + length(marker))
      colon=index(rest, ":"); if (!colon) exit 1
      rest=substr(rest, colon + 1)
      array=index(rest, "["); if (!array) exit 1
      rest=substr(rest, array + 1)
      for (object=1; object<=length(rest); object++) {
        ch=substr(rest, object, 1)
        if (ch ~ /[[:space:]]/) continue
        if (ch != "{") exit 1
        break
      }
      if (object > length(rest)) exit 1
      rest=substr(rest, object)
      depth=0; quoted=0; escaped=0
      for (i=1; i<=length(rest); i++) {
        ch=substr(rest, i, 1)
        if (quoted) {
          if (escaped) escaped=0
          else if (ch == "\\") escaped=1
          else if (ch == "\"") quoted=0
        } else if (ch == "\"") quoted=1
        else if (ch == "{") depth++
        else if (ch == "}") {
          depth--
          if (depth == 0) { print substr(rest, 1, i); exit 0 }
        }
      }
      exit 1
    }
  ' "$file"
}

cio_lock() {
  lock=$1 max_attempts=${2:-100} attempts=0
  case "$max_attempts" in ''|*[!0-9]*) cio_die UNSAFE_LOCK ;; esac
  [ "$max_attempts" -ge 1 ] || cio_die UNSAFE_LOCK
  while ! (
    trap '' HUP INT TERM
    lock_initializing=false
    cleanup_lock_initialization() {
      if [ "$lock_initializing" = true ]; then
        /bin/rm -f "$lock/owner"
        /bin/rmdir "$lock" 2>/dev/null || true
      fi
    }
    trap cleanup_lock_initialization EXIT
    /bin/mkdir -m 700 "$lock" 2>/dev/null || exit 1
    lock_initializing=true
    cio_validate_dir "$lock" || exit 1
    printf '%s\n' "$$" | cio_atomic_write "$lock/owner"
    lock_initializing=false
    trap - EXIT
  ); do
    if [ ! -d "$lock" ] || [ -L "$lock" ]; then cio_die UNSAFE_LOCK; fi
    owner=$lock/owner
    if cio_validate_file "$owner"; then
      owner_pid=$(sed -n '1p' "$owner")
      case "$owner_pid" in
        ''|*[!0-9]*) ;;
        *)
          if ! kill -0 "$owner_pid" 2>/dev/null; then
            /bin/rm -f "$owner"
            /bin/rmdir "$lock" 2>/dev/null || true
            continue
          fi
          ;;
      esac
    fi
    attempts=$((attempts + 1))
    [ "$attempts" -lt "$max_attempts" ] || cio_die BUSY 75
    /bin/sleep 0.1
  done
  cio_validate_dir "$lock" || cio_die UNSAFE_LOCK
  cio_validate_file "$lock/owner" || cio_die UNSAFE_LOCK
  [ "$(sed -n '1p' "$lock/owner")" = "$$" ] || cio_die UNSAFE_LOCK
}

cio_unlock() {
  /bin/rm -f "$1/owner"
  /bin/rmdir "$1" 2>/dev/null || cio_die LOCK_RELEASE_FAILED
}

cio_temp_file() {
  target=$cio_state/.tmp.$$.$(openssl rand -hex 8)
  ( set -C; : >"$target" ) 2>/dev/null || cio_die STATE_WRITE_FAILED
  /bin/chmod 600 "$target"
  if [ "$(uname -s)" = Darwin ]; then /bin/chmod -N "$target" || cio_die STATE_WRITE_FAILED; fi
  printf '%s\n' "$target"
}

cio_install_file() {
  origin=$1
  printf '%s/install-%s-%s' "$cio_state" "$cio_host" "$(cio_origin_key "$origin")"
}

cio_pending_file() {
  origin=$1
  printf '%s/pair-%s-%s' "$cio_state" "$cio_host" "$(cio_origin_key "$origin")"
}

cio_conversation_id() {
  case "$cio_host" in
    claude-code) value=${CLAUDE_CODE_SESSION_ID:-} ;;
    codex) value=${CODEX_THREAD_ID:-} ;;
  esac
  case "$value" in ''|*[!A-Za-z0-9._:-]*) cio_die CONVERSATION_ID_UNAVAILABLE 3 ;; esac
  [ "${#value}" -le 1024 ] || cio_die CONVERSATION_ID_UNAVAILABLE 3
  printf '%s\n' "$value"
}

cio_stat_mtime() {
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f '%m' "$1" ;;
    Linux) /usr/bin/stat -c '%Y' "$1" ;;
    *) cio_die UNSUPPORTED_HOST 64 ;;
  esac
}

cio_discover_conversation_origins() {
  conversation=$(cio_conversation_id) || return 1
  conv=$(cio_hash "$conversation")
  found=0
  for file in "$cio_state"/binding-"$cio_host"-*-"$conv"; do
    [ -f "$file" ] || continue
    cio_validate_file "$file" || continue
    origin_value=$(cio_field "$file" origin) || continue
    origin_value=$(cio_origin "$origin_value" 2>/dev/null) || continue
    printf '%s\n' "$origin_value"
    found=1
  done
  [ "$found" = 1 ]
}

cio_discover_conversation_origin() {
  latest=
  latest_mtime=0
  while IFS= read -r origin_value; do
    [ -n "$origin_value" ] || continue
    file=$(cio_binding_file "$origin_value" "$(cio_conversation_id)")
    mtime=$(cio_stat_mtime "$file") || continue
    if [ -z "$latest" ] || [ "$mtime" -ge "$latest_mtime" ]; then
      latest=$origin_value
      latest_mtime=$mtime
    fi
  done <<EOF
$(cio_discover_conversation_origins || true)
EOF
  [ -n "$latest" ] || return 1
  printf '%s\n' "$latest"
}

cio_identity_file() {
  origin=$1 conversation=$2
  printf '%s/identity-%s-%s-%s' "$cio_state" "$cio_host" "$(cio_origin_key "$origin")" "$(cio_hash "$conversation")"
}

cio_listen_identity_file() {
  origin=$1 conversation=$2
  printf '%s/listen-identity-%s-%s-%s' "$cio_state" "$cio_host" "$(cio_origin_key "$origin")" "$(cio_hash "$conversation")"
}

cio_binding_file() {
  origin=$1 conversation=$2
  printf '%s/binding-%s-%s-%s' "$cio_state" "$cio_host" "$(cio_origin_key "$origin")" "$(cio_hash "$conversation")"
}

cio_curl() {
  credential_file=$1 method=$2 origin=$3 path=$4 body_file=$5 output_file=$6
  case "$method" in GET|POST|PATCH|PUT|DELETE) ;; *) cio_die INVALID_METHOD 64 ;; esac
  case "$path" in /*) ;; *) cio_die INVALID_PATH 64 ;; esac
  case "$path" in *'://'*|*' '*) cio_die INVALID_PATH 64 ;; esac
  secret=$(cio_field "$credential_file" secret) || cio_die CREDENTIAL_UNAVAILABLE 2
  case "$secret" in amk_*|as_*|ct_*|dt_*|usk_*|pst_*|eat_*|dat_*) ;; *) cio_die CREDENTIAL_INVALID 2 ;; esac
  config=$(cio_temp_file)
  {
    printf '%s\n' 'silent' 'show-error' 'proto = "=https"' 'proto-redir = "=https"' 'max-redirs = 0' 'connect-timeout = 10' 'max-time = 40'
    printf 'header = "Authorization: Bearer %s"\n' "$secret"
    printf '%s\n' 'header = "Accept: application/json"'
  } | cio_atomic_write "$config"
  set +e
  if [ -n "$body_file" ]; then
    cio_validate_file "$body_file" || cio_die UNSAFE_BODY_FILE
    code=$(curl --config "$config" --request "$method" --header 'Content-Type: application/json' \
      --data-binary "@$body_file" --output "$output_file" --write-out '%{http_code}' "$origin$path")
    rc=$?
  else
    code=$(curl --config "$config" --request "$method" --output "$output_file" \
      --write-out '%{http_code}' "$origin$path")
    rc=$?
  fi
  set -e
  /bin/rm -f "$config"
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s\n' "$code"
}

cio_post_json() {
  credential=$1 origin=$2 path=$3 json=$4 output=$5 idempotency=${6:-}
  body=$(cio_temp_file)
  printf '%s\n' "$json" | cio_atomic_write "$body"
  if [ -n "$idempotency" ]; then
    config=$(cio_temp_file)
    secret=$(cio_field "$credential" secret) || cio_die CREDENTIAL_UNAVAILABLE 2
    {
      printf '%s\n' 'silent' 'show-error' 'proto = "=https"' 'proto-redir = "=https"' 'max-redirs = 0' 'connect-timeout = 10' 'max-time = 40'
      printf 'header = "Authorization: Bearer %s"\n' "$secret"
      printf 'header = "Idempotency-Key: %s"\n' "$idempotency"
      printf '%s\n' 'header = "Accept: application/json"' 'header = "Content-Type: application/json"'
    } | cio_atomic_write "$config"
    code=$(curl --config "$config" --request POST --data-binary "@$body" --output "$output" --write-out '%{http_code}' "$origin$path") || { /bin/rm -f "$body" "$config"; return 1; }
    /bin/rm -f "$config"
  else
    code=$(cio_curl "$credential" POST "$origin" "$path" "$body" "$output") || { /bin/rm -f "$body"; return 1; }
  fi
  /bin/rm -f "$body"
  printf '%s\n' "$code"
}

cio_redact() {
  sed -E \
    -e 's/(amk|ark|as|ct|dt|usk|pst|pdc|eat|dat|wwt)_[A-Za-z0-9._:-]+/[REDACTED]/g' \
    -e 's/\"(agent_secret|access_token|source_token|socket_ticket|device_code|agent_mint_key|token)\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"\1\":\"[REDACTED]\"/g'
}

cio_safe_id() {
  value=$1
  [ -n "$value" ] && [ "${#value}" -le "${2:-256}" ] || return 1
  case "$value" in *[!A-Za-z0-9._:-]*) return 1 ;; esac
}

cio_atomic_append_field() {
  target=$1 key=$2 value=$3
  cio_validate_file "$target" || cio_die UNSAFE_STATE
  case "$key" in ''|*[!A-Za-z0-9_]*) cio_die INVALID_STATE_FIELD ;; esac
  cio_safe_id "$value" 256 || cio_die INVALID_STATE_FIELD
  temporary=$(cio_temp_file)
  { /bin/cat "$target"; printf '%s=%s\n' "$key" "$value"; } | cio_atomic_write "$temporary"
  cio_atomic_write "$target" <"$temporary"
  /bin/rm -f "$temporary"
}

cio_terminal_operation() {
  target=$1 action=$2 proposed=$3 signature=$4
  cio_validate_file "$target" || cio_die UNSAFE_STATE
  terminal_lock=$target.terminal-lock
  cio_lock "$terminal_lock"
  signature_hash=$(cio_hash "$action:$signature")
  stored_action=$(cio_field "$target" terminal_action 2>/dev/null || true)
  stored_operation=$(cio_field "$target" terminal_operation_id 2>/dev/null || true)
  stored_hash=$(cio_field "$target" terminal_request_hash 2>/dev/null || true)
  if [ -n "$stored_operation" ]; then
    [ "$stored_action" = "$action" ] && [ "$stored_hash" = "$signature_hash" ] \
      || cio_die TERMINAL_RETRY_MISMATCH 64
    [ -z "$proposed" ] || [ "$proposed" = "$stored_operation" ] \
      || cio_die TERMINAL_RETRY_MISMATCH 64
    CIO_TERMINAL_OPERATION=$stored_operation
    export CIO_TERMINAL_OPERATION
    cio_unlock "$terminal_lock"
    return
  fi
  [ -z "$stored_action$stored_hash" ] || cio_die TERMINAL_STATE_INVALID
  selected=${proposed:-$(printf 'op_%s' "$(openssl rand -hex 16)")}
  cio_safe_id "$selected" 128 || cio_die INVALID_OPERATION 64
  temporary=$(cio_temp_file)
  {
    /bin/cat "$target"
    printf 'terminal_action=%s\nterminal_operation_id=%s\nterminal_request_hash=%s\n' \
      "$action" "$selected" "$signature_hash"
  } | cio_atomic_write "$temporary"
  cio_atomic_write "$target" <"$temporary"
  /bin/rm -f "$temporary"
  CIO_TERMINAL_OPERATION=$selected
  export CIO_TERMINAL_OPERATION
  cio_unlock "$terminal_lock"
}

cio_credential_for_path() {
  origin=$1 path=$2 identity=$3
  slug=$(printf '%s' "$path" | sed -n 's|^/docs/\([a-z0-9][a-z0-9-]*\).*|\1|p')
  if [ -n "$slug" ]; then
    document=$cio_state/document-$cio_host-$(cio_origin_key "$origin")-$slug
    if cio_validate_file "$document"; then printf '%s\n' "$document"; return; fi
  fi
  printf '%s\n' "$identity"
}
