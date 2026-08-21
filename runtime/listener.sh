#!/bin/sh

set -eu
umask 077

listener_dir=$(CDPATH='' cd "$(dirname "$0")" && /bin/pwd -P)
runtime_dir=$listener_dir
. "$listener_dir/host.sh"
. "$listener_dir/lib.sh"

action=${1:-}
origin=$(cio_origin "${2:-https://comment.io}")
owner_nonce=${3:-}
conversation=$(cio_conversation_id)
binding=$(cio_binding_file "$origin" "$conversation")

load_binding() {
  cio_validate_file "$binding" || return 1
  identity=$(cio_field "$binding" identity)
  cio_validate_file "$identity" || return 1
  generation=$(cio_field "$binding" binding_generation)
  contract=$(cio_field "$binding" delivery_contract 2>/dev/null || true)
  if [ "$contract" = agent_work_wake_v1 ]; then
    session=
    case "$generation" in [1-9]*) ;; *) return 1 ;; esac
    return 0
  fi
  session=$(cio_field "$binding" plugin_session_id)
  case "$session:$generation" in ps_*:[1-9]*) ;; *) return 1 ;; esac
}

work_wake_binding() {
  [ "$(cio_field "$binding" delivery_contract 2>/dev/null || true)" = agent_work_wake_v1 ]
}

work_auth_fields() {
  extra=
  if [ -n "${generation:-}" ]; then
    extra=$(printf ',"binding_generation":%s' "$generation")
  fi
  owner=$(cio_field "$identity" owner_agent_id 2>/dev/null || true)
  grant=$(cio_field "$identity" grant_id 2>/dev/null || true)
  revocation=$(cio_field "$identity" grant_revocation_generation 2>/dev/null || true)
  if [ -n "$owner" ] && [ -n "$grant" ] && [ -n "$revocation" ]; then
    printf ',"owner_agent_id":"%s","grant_id":"%s","grant_revocation_generation":%s%s' \
      "$owner" "$grant" "$revocation" "$extra"
    return
  fi
  printf '%s' "$extra"
}

work_item_ids_json() {
  ids=$1
  json=
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $ids
  IFS=$old_ifs
  for id in "$@"; do
    case "$id" in wit_*) ;; *) cio_die INVALID_WORK_ITEM 64 ;; esac
    cio_safe_id "$id" 120 || cio_die INVALID_WORK_ITEM 64
    if [ -n "$json" ]; then json=$json,; fi
    json=$json$(printf '"%s"' "$id")
  done
  [ -n "$json" ] || cio_die INVALID_WORK_ITEM 64
  printf '{"work_item_ids":[%s]%s}' "$json" "$(work_auth_fields)"
}

extract_work_item_ids() {
  sed 's/}/\n/g' "$1" | sed -n 's/.*"work_item_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | paste -sd, -
}

extract_acknowledged_work_item_ids() {
  tr -d '\n' <"$1" | sed -n 's/.*"work_item_ids"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | tr -d '" '
}

set_work_batch_count() {
  next=$1
  lock=$binding.bind-lock
  cio_lock "$lock"
  if ! cio_validate_file "$binding" \
    || [ "$(cio_field "$binding" binding_generation 2>/dev/null || true)" != "$generation" ]; then
    cio_unlock "$lock"
    return 1
  fi
  temporary=$(cio_temp_file)
  { grep -v '^work_batch_count=' "$binding" || true; printf 'work_batch_count=%s\n' "$next"; } | cio_atomic_write "$temporary"
  cio_atomic_write "$binding" <"$temporary"
  /bin/rm -f "$temporary"
  cio_unlock "$lock"
}

remaining_work_item_ids() {
  claimed=$1
  selected=$2
  remaining=
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $claimed
  IFS=$old_ifs
  for id in "$@"; do
    case ",$selected," in
      *",$id,"*) ;;
      *)
        if [ -n "$remaining" ]; then remaining=$remaining,; fi
        remaining=$remaining$id
        ;;
    esac
  done
  printf '%s' "$remaining"
}

work_attempt_lock_attempts() {
  attempt=$1
  ids=$(cio_field "$attempt" claimed_work_item_ids 2>/dev/null || true)
  [ -n "$ids" ] || ids=$(cio_field "$attempt" work_item_ids 2>/dev/null || true)
  [ -n "$ids" ] || { printf '%s\n' 500; return; }
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $ids
  IFS=$old_ifs
  chunks=$((($# + 49) / 50))
  # Each chunk can consume cio_curl's full 40-second bound. Add the ordinary
  # ten-second lock window as scheduling and local-I/O headroom.
  printf '%s\n' $((100 + (chunks * 400)))
}

release_work_ids() {
  ids=$1
  [ -n "$ids" ] || return 0
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $ids
  IFS=$old_ifs
  while [ "$#" -gt 0 ]; do
    chunk=
    count=0
    while [ "$#" -gt 0 ] && [ "$count" -lt 50 ]; do
      if [ -n "$chunk" ]; then chunk=$chunk,; fi
      chunk=$chunk$1
      shift
      count=$((count + 1))
    done
    request=$(cio_temp_file); response=$(cio_temp_file)
    work_item_ids_json "$chunk" | cio_atomic_write "$request"
    code=$(cio_curl "$identity" POST "$origin" /agents/me/work/release "$request" "$response") || {
      /bin/rm -f "$request" "$response"
      return 1
    }
    /bin/rm -f "$request"
    case "$code" in
      200|409) /bin/rm -f "$response" ;;
      *) cio_redact <"$response" >&2; /bin/rm -f "$response"; return 1 ;;
    esac
  done
}

publish_received_work() {
  ids=$1
  next=$2
  lock=$binding.bind-lock
  cio_lock "$lock"
  if cio_validate_file "$(attempt_file)"; then
    cio_unlock "$lock"
    return 2
  fi
  if ! cio_validate_file "$binding" \
    || [ "$(cio_field "$binding" binding_generation 2>/dev/null || true)" != "$generation" ]; then
    cio_unlock "$lock"
    return 1
  fi
  temporary=$(cio_temp_file)
  { grep -v '^work_batch_count=' "$binding" || true; printf 'work_batch_count=%s\n' "$next"; } | cio_atomic_write "$temporary"
  cio_atomic_write "$binding" <"$temporary"
  /bin/rm -f "$temporary"
  {
    printf 'kind=work\norigin=%s\nidentity=%s\nbinding_generation=%s\n' "$origin" "$identity" "$generation"
    printf 'work_item_ids=%s\nclaimed_work_item_ids=%s\n' "$ids" "$ids"
  } | cio_atomic_write "$(attempt_file)"
  cio_unlock "$lock"
}

receive_work() {
  batches=$(cio_field "$binding" work_batch_count 2>/dev/null || true)
  case "$batches" in ''|*[!0-9]*) batches=0 ;; esac
  [ "$batches" -lt 3 ] || cio_die WORK_BATCH_LIMIT 2
  if cio_validate_file "$(attempt_file)"; then cio_die WORK_IN_PROGRESS 75; fi
  request=$(cio_temp_file); response=$(cio_temp_file)
  printf '{%s}\n' "$(work_auth_fields | sed 's/^,//')" | cio_atomic_write "$request"
  code=$(cio_curl "$identity" POST "$origin" /agents/me/work/next "$request" "$response") || cio_die RECEIVE_FAILED
  /bin/rm -f "$request"
  [ "$code" = 200 ] || { cio_redact <"$response" >&2; /bin/rm -f "$response"; cio_die RECEIVE_FAILED; }
  ids=$(extract_work_item_ids "$response")
  if [ -z "$ids" ]; then
    cio_redact <"$response"
    /bin/rm -f "$response"
    return 0
  fi
  set +e
  publish_received_work "$ids" $((batches + 1))
  publish_rc=$?
  set -e
  if [ "$publish_rc" -ne 0 ]; then
    /bin/rm -f "$response"
    if [ "$publish_rc" -eq 2 ]; then cio_die WORK_IN_PROGRESS 75; fi
    release_work_ids "$ids" || true
    cio_die NOT_LISTENING 2
  fi
  cio_redact <"$response"
  /bin/rm -f "$response"
}

complete_work() (
  attempt_lock=$binding.attempt-lock
  attempt_lock_held=false
  release_attempt_lock() {
    if [ "$attempt_lock_held" = true ]; then
      attempt_lock_held=false
      cio_unlock "$attempt_lock" >/dev/null 2>&1 || true
    fi
  }
  trap release_attempt_lock EXIT
  cio_lock "$attempt_lock" "$(work_attempt_lock_attempts "$(attempt_file)")"
  attempt_lock_held=true
  ids=$1
  [ -n "$ids" ] || cio_die USAGE 64
  attempt=$(attempt_file)
  cio_validate_file "$attempt" || cio_die NO_CLAIMED_WORK 2
  [ "$(cio_field "$attempt" kind)" = work ] || cio_die ATTEMPT_INVALID
  work_item_ids_json "$ids" >/dev/null
  remaining_ids=$(cio_field "$attempt" work_item_ids)
  claimed_ids=$(cio_field "$attempt" claimed_work_item_ids 2>/dev/null || true)
  settlement_ids=$ids
  if [ -n "$claimed_ids" ]; then
    [ -z "$(remaining_work_item_ids "$ids" "$claimed_ids")" ] || cio_die INVALID_WORK_ITEM 64
  else
    # Legacy attempts record only the IDs that remain unacknowledged. Intersect
    # a retry with that persisted set so previously acknowledged IDs stay
    # retryable without sending IDs that this attempt cannot prove it claimed.
    settlement_ids=$(remaining_work_item_ids "$ids" "$(remaining_work_item_ids "$ids" "$remaining_ids")")
    [ -n "$settlement_ids" ] || cio_die INVALID_WORK_ITEM 64
  fi
  completed_ids=
  old_ifs=$IFS
  IFS=,
  # shellcheck disable=SC2086
  set -- $settlement_ids
  IFS=$old_ifs
  while [ "$#" -gt 0 ]; do
    chunk=
    count=0
    while [ "$#" -gt 0 ] && [ "$count" -lt 50 ]; do
      if [ -n "$chunk" ]; then chunk=$chunk,; fi
      chunk=$chunk$1
      shift
      count=$((count + 1))
    done
    request=$(cio_temp_file); response=$(cio_temp_file)
    work_item_ids_json "$chunk" | cio_atomic_write "$request"
    code=$(cio_curl "$identity" POST "$origin" /agents/me/work/complete "$request" "$response") || cio_die SETTLE_FAILED
    /bin/rm -f "$request"
    [ "$code" = 200 ] || { cio_redact <"$response" >&2; /bin/rm -f "$response"; cio_die SETTLE_FAILED; }
    acknowledged=$(extract_acknowledged_work_item_ids "$response")
    /bin/rm -f "$response"
    [ -n "$acknowledged" ] || continue
    remaining=$(remaining_work_item_ids "$(cio_field "$attempt" work_item_ids)" "$acknowledged")
    if [ -z "$remaining" ]; then
      /bin/rm -f "$attempt" "$(payload_file)"
    else
      temporary=$(cio_temp_file)
      { grep -v '^work_item_ids=' "$attempt" || true; printf 'work_item_ids=%s\n' "$remaining"; } | cio_atomic_write "$temporary"
      cio_atomic_write "$attempt" <"$temporary"
      /bin/rm -f "$temporary"
    fi
    completed_ids=1
  done
  [ -n "$completed_ids" ] || cio_die SETTLE_FAILED
  if cio_validate_file "$(attempt_file)"; then
    leftover=$(remaining_work_item_ids "$settlement_ids" "$(remaining_work_item_ids "$settlement_ids" "$(cio_field "$(attempt_file)" work_item_ids)")")
    [ -z "$leftover" ] || cio_die SETTLE_FAILED
  fi
  printf '%s\n' COMPLETED
)

release_work() (
  attempt_lock=$binding.attempt-lock
  attempt_lock_held=false
  release_attempt_lock() {
    if [ "$attempt_lock_held" = true ]; then
      attempt_lock_held=false
      cio_unlock "$attempt_lock" >/dev/null 2>&1 || true
    fi
  }
  trap release_attempt_lock EXIT
  cio_lock "$attempt_lock" "$(work_attempt_lock_attempts "$(attempt_file)")"
  attempt_lock_held=true
  attempt=$(attempt_file)
  cio_validate_file "$attempt" || cio_die NO_CLAIMED_WORK 2
  [ "$(cio_field "$attempt" kind)" = work ] || cio_die ATTEMPT_INVALID
  ids=$(cio_field "$attempt" work_item_ids)
  release_work_ids "$ids" || cio_die RELEASE_FAILED
  /bin/rm -f "$attempt" "$(payload_file)"
  printf '%s\n' RELEASED
)

load_codex_binding_identity() {
  load_binding || return 1
  [ "$cio_host" = codex ] || return 1
  bound_socket_device=$(cio_field "$binding" codex_socket_device 2>/dev/null || true)
  bound_socket_inode=$(cio_field "$binding" codex_socket_inode 2>/dev/null || true)
  bound_thread_session_id=$(cio_field "$binding" codex_thread_session_id 2>/dev/null || true)
  bound_runner_process_id=$(cio_field "$binding" codex_runner_process_id 2>/dev/null || true)
  case "$bound_socket_device" in ''|*[!0-9]*) return 1 ;; esac
  case "$bound_socket_inode" in ''|*[!0-9]*) return 1 ;; esac
  case "$bound_runner_process_id" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$bound_thread_session_id" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$' || return 1
}

attempt_file() { printf '%s.attempt' "$binding"; }
payload_file() { printf '%s.payload' "$binding"; }
keeper_file() { printf '%s.keeper' "$binding"; }
pickup_file() { printf '%s.pickup' "$binding"; }

owned_process() {
  record=$1 expected_action=$2
  cio_validate_file "$record" || return 1
  process_pid=$(sed -n '1p' "$record")
  process_nonce=$(sed -n '2p' "$record")
  case "$process_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$process_nonce" in ''|*[!A-Za-z0-9._:-]*) return 1 ;; esac
  kill -0 "$process_pid" 2>/dev/null || return 1
  process_command=$(/bin/ps -ww -p "$process_pid" -o command= 2>/dev/null) || return 1
  case "$process_command" in
    setsid\ *|*/setsid\ *) return 1 ;;
    *"$listener_dir/listener.sh $expected_action $origin $process_nonce"*) return 0 ;;
    *) return 1 ;;
  esac
}

term_group() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  # dash's builtin kill rejects `kill -TERM -- -PID`. Use the external kill.
  /bin/kill -TERM -- -"$1" 2>/dev/null || /bin/kill -TERM "$1" 2>/dev/null || true
}

retire_process_record() {
  record=$1 expected_action=$2
  if owned_process "$record" "$expected_action"; then
    term_group "$process_pid"
  fi
  /bin/rm -f "$record"
}

discard_local_attempt() {
  stop_keeper
  /bin/rm -f "$(attempt_file)" "$(payload_file)"
}

operation_id() { printf 'op_%s\n' "$(openssl rand -hex 16)"; }

binding_current() {
  expected_session=$1 expected_generation=$2
  cio_validate_file "$binding" || return 1
  [ "$(cio_field "$binding" binding_generation)" = "$expected_generation" ] || return 1
  if work_wake_binding; then
    return 0
  fi
  [ "$(cio_field "$binding" plugin_session_id)" = "$expected_session" ]
}

release_snapshot_file() {
  printf '%s/.release.%s.%s.%s\n' "$cio_state" "$cio_host" "$(cio_origin_key "$origin")" "$(openssl rand -hex 8)"
}

stage_ordinary_release() {
  release_snapshot=$(release_snapshot_file)
  {
    printf 'kind=ordinary\norigin=%s\nidentity=%s\nplugin_session_id=%s\nbinding_generation=%s\n' "$origin" "$identity" "$session" "$generation"
    printf 'claim_id=%s\nnotification_id=%s\n' "$claim" "$notification"
  } | cio_atomic_write "$release_snapshot"
}

stage_canonical_release() {
  release_snapshot=$(release_snapshot_file)
  {
    printf 'kind=canonical\norigin=%s\nidentity=%s\nplugin_session_id=%s\nbinding_generation=%s\n' "$origin" "$identity" "$session" "$generation"
    printf 'locator_id=%s\nclaimant_id=%s\n' "$locator" "$claimant"
  } | cio_atomic_write "$release_snapshot"
}

lease_ordinary() (
  trap '' HUP INT TERM
  response=$1
  op=$(operation_id)
  json=$(printf '{"delivery_contract":"plugin_session_v1","plugin_session_id":"%s","binding_generation":%s,"lease_holder":"session:%s","limit":1}' "$session" "$generation" "$(cio_hash "$conversation")")
  code=$(cio_post_json "$identity" "$origin" /agents/me/notifications/lease "$json" "$response" "$op") || return 75
  if [ "$code" != 200 ]; then
    case "$code" in 429|5??) return 75 ;; *) return 1 ;; esac
  fi
  object=$(cio_json_first_object leases "$response")
  [ -n "$object" ] || return 1
  lease_file=$(cio_temp_file)
  printf '%s\n' "$object" | cio_atomic_write "$lease_file"
  claim=$(cio_json_string claim_id "$lease_file")
  notification=$(cio_json_string notification_id "$lease_file")
  if ! cio_safe_id "$claim" 120 || ! cio_safe_id "$notification" 120; then /bin/rm -f "$lease_file"; return 1; fi
  stage_ordinary_release
  attempt=$(attempt_file)
  payload=$(payload_file)
  publication_lock=$binding.bind-lock
  publication_lock_held=true
  release_publication_lock() {
    if [ "$publication_lock_held" = true ] && cio_validate_file "$publication_lock/owner" \
      && [ "$(sed -n '1p' "$publication_lock/owner")" = "$$" ]; then
      publication_lock_held=false
      cio_unlock "$publication_lock" >/dev/null 2>&1 || true
    fi
  }
  trap release_publication_lock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cio_lock "$publication_lock"
  if ! binding_current "$session" "$generation" || cio_validate_file "$attempt"; then
    cio_unlock "$publication_lock"
    publication_lock_held=false
    trap - EXIT HUP INT TERM
    release_file "$release_snapshot" >/dev/null 2>&1 || true
    /bin/rm -f "$lease_file"
    return 1
  fi
  cio_atomic_write "$payload" <"$lease_file"
  /bin/mv "$release_snapshot" "$attempt"
  cio_validate_file "$attempt" || cio_die STATE_WRITE_FAILED
  cio_unlock "$publication_lock"
  publication_lock_held=false
  trap - EXIT HUP INT TERM
  /bin/rm -f "$lease_file"
)

pickup_canonical() (
  trap '' HUP INT TERM
  locator=$1 connection=$2 response=$3
  pickup=$(pickup_file)
  if cio_validate_file "$pickup"; then
    saved_locator=$(cio_field "$pickup" locator_id 2>/dev/null || true)
    [ "$saved_locator" = "$locator" ] || return 1
    op=$(cio_field "$pickup" operation_id)
  else
    op=$(operation_id)
    { printf 'locator_id=%s\noperation_id=%s\n' "$locator" "$op"; } | cio_atomic_write "$pickup"
  fi
  json=$(printf '{"plugin_session_id":"%s","binding_generation":%s,"plugin_connection_id":"%s","operation_id":"%s"}' "$session" "$generation" "$connection" "$op")
  code=$(cio_post_json "$identity" "$origin" "/agents/me/agent-interactions/$locator/plugin-pickup" "$json" "$response" "$op") || return 75
  if [ "$code" != 200 ]; then
    case "$code" in
      429|5??) return 75 ;;
      *) /bin/rm -f "$pickup" ;;
    esac
    return 1
  fi
  claimant=$(cio_json_string claimant_id "$response")
  case "$locator:$connection:$claimant" in ail_*:psc_*:aic_*) ;; *) return 1 ;; esac
  cio_safe_id "$locator" 80 && cio_safe_id "$connection" 80 && cio_safe_id "$claimant" 80 || return 1
  stage_canonical_release
  attempt=$(attempt_file)
  payload=$(payload_file)
  publication_lock=$binding.bind-lock
  publication_lock_held=true
  release_publication_lock() {
    if [ "$publication_lock_held" = true ] && cio_validate_file "$publication_lock/owner" \
      && [ "$(sed -n '1p' "$publication_lock/owner")" = "$$" ]; then
      publication_lock_held=false
      cio_unlock "$publication_lock" >/dev/null 2>&1 || true
    fi
  }
  trap release_publication_lock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  cio_lock "$publication_lock"
  if ! binding_current "$session" "$generation" || cio_validate_file "$attempt"; then
    cio_unlock "$publication_lock"
    publication_lock_held=false
    trap - EXIT HUP INT TERM
    /bin/rm -f "$pickup"
    release_file "$release_snapshot" >/dev/null 2>&1 || true
    return 1
  fi
  cio_atomic_write "$payload" <"$response"
  /bin/mv "$release_snapshot" "$attempt"
  cio_validate_file "$attempt" || cio_die STATE_WRITE_FAILED
  cio_unlock "$publication_lock"
  publication_lock_held=false
  trap - EXIT HUP INT TERM
  /bin/rm -f "$pickup"
)

send_ws_text() {
  payload=$1 length=${#1}
  [ "$length" -le 65535 ] || cio_die WS_FRAME_TOO_LARGE
  # Four random mask bytes are required for every client frame.
  # shellcheck disable=SC2086
  set -- $(od -An -N4 -tu1 /dev/urandom)
  [ "$#" -eq 4 ] || cio_die WS_RANDOM_FAILED
  a=$1 b=$2 c=$3 d=$4
  awk -v n="$length" -v a="$a" -v b="$b" -v c="$c" -v d="$d" 'BEGIN {
    printf "%c", 129
    if (n < 126) printf "%c", 128 + n
    else printf "%c%c%c", 254, int(n / 256), n % 256
    printf "%c%c%c%c", a, b, c, d
  }' >&3
  printf '%s' "$payload" | od -An -v -tu1 | awk -v a="$a" -v b="$b" -v c="$c" -v d="$d" '
    function bxor(x,y,r,p){r=0;p=1;while(x>0||y>0){if((x%2)!=(y%2))r+=p;x=int(x/2);y=int(y/2);p*=2}return r}
    {for(i=1;i<=NF;i++){m=((count%4)==0?a:(count%4)==1?b:(count%4)==2?c:d);printf "%c",bxor($i,m);count++}}' >&3
}

send_ws_pong() {
  payload=$1 length=${#1}
  [ "$length" -le 125 ] || return 1
  # shellcheck disable=SC2086
  set -- $(od -An -N4 -tu1 /dev/urandom)
  [ "$#" -eq 4 ] || return 1
  a=$1 b=$2 c=$3 d=$4
  awk -v n="$length" -v a="$a" -v b="$b" -v c="$c" -v d="$d" 'BEGIN {
    printf "%c%c%c%c%c%c", 138, 128 + n, a, b, c, d
  }' >&3
  printf '%s' "$payload" | od -An -v -tu1 | awk -v a="$a" -v b="$b" -v c="$c" -v d="$d" '
    function bxor(x,y,r,p){r=0;p=1;while(x>0||y>0){if((x%2)!=(y%2))r+=p;x=int(x/2);y=int(y/2);p*=2}return r}
    {for(i=1;i<=NF;i++){m=((count%4)==0?a:(count%4)==1?b:(count%4)==2?c:d);printf "%c",bxor($i,m);count++}}' >&3
}

read_ws_text() {
  header=$(dd bs=1 count=2 <&4 2>/dev/null | od -An -tu1)
  # shellcheck disable=SC2086
  set -- $header
  [ "$#" -eq 2 ] || return 1
  first=$1 second=$2 opcode=$((first % 16))
  [ "$second" -lt 128 ] || return 1
  length=$second
  if [ "$length" -eq 126 ]; then
    extended=$(dd bs=1 count=2 <&4 2>/dev/null | od -An -tu1)
    # shellcheck disable=SC2086
    set -- $extended
    [ "$#" -eq 2 ] || return 1
    length=$(($1 * 256 + $2))
  elif [ "$length" -eq 127 ]; then return 1; fi
  [ "$length" -le 1048576 ] || return 1
  WS_MESSAGE=$(dd bs=1 count="$length" <&4 2>/dev/null)
  [ "${#WS_MESSAGE}" -eq "$length" ] || return 1
  case "$opcode" in
    1) return 0 ;;
    8) return 1 ;;
    9) return 2 ;;
    10) return 3 ;;
    *) return 3 ;;
  esac
}

wait_ws_response() {
  response_id=$1
  while :; do
    set +e
    read_ws_text
    frame_rc=$?
    set -e
    case "$frame_rc" in
      0)
        if printf '%s' "$WS_MESSAGE" | grep -Eq '"id"[[:space:]]*:[[:space:]]*'"$response_id"'([,}])'; then
          WS_RESPONSE=$WS_MESSAGE
          return 0
        fi
        ;;
      2) send_ws_pong "$WS_MESSAGE" || return 1 ;;
      3) ;;
      *) return 1 ;;
    esac
  done
}

codex_socket_reason() {
  codex_control_dir=${CODEX_HOME:-$HOME/.codex}/app-server-control
  codex_socket=$codex_control_dir/app-server-control.sock
  if ! cio_validate_dir "$codex_control_dir"; then
    if [ ! -e "$codex_control_dir" ]; then printf '%s\n' app_server_absent
    else printf '%s\n' app_server_untrusted
    fi
    return 1
  fi
  if [ -L "$codex_socket" ]; then printf '%s\n' app_server_untrusted; return 1; fi
  if [ ! -e "$codex_socket" ]; then printf '%s\n' app_server_absent; return 1; fi
  if [ ! -S "$codex_socket" ] || [ "$(cio_stat_owner "$codex_socket" 2>/dev/null || true)" != "$cio_uid" ]; then
    printf '%s\n' app_server_untrusted
    return 1
  fi
  codex_socket_device=$(cio_stat_device "$codex_socket" 2>/dev/null || true)
  codex_socket_inode=$(cio_stat_inode "$codex_socket" 2>/dev/null || true)
  case "$codex_socket_device" in ''|*[!0-9]*) printf '%s\n' app_server_untrusted; return 1 ;; esac
  case "$codex_socket_inode" in ''|*[!0-9]*) printf '%s\n' app_server_untrusted; return 1 ;; esac
  return 0
}

codex_bound_endpoint_current() {
  codex_socket_reason >/dev/null || return 1
  [ "$codex_socket_device" = "$bound_socket_device" ] \
    && [ "$codex_socket_inode" = "$bound_socket_inode" ]
}

codex_bound_identity_current() {
  expected_identity="ready:$bound_socket_device:$bound_socket_inode:$bound_thread_session_id:$bound_runner_process_id"
  [ "$(codex_preflight)" = "$expected_identity" ]
}

codex_require_loaded_thread() {
  loaded_cursor=
  loaded_seen=
  loaded_pages=0
  while [ "$loaded_pages" -lt 100 ]; do
    loaded_pages=$((loaded_pages + 1))
    id=$((id + 1))
    if [ -n "$loaded_cursor" ]; then
      send_ws_text "{\"id\":$id,\"method\":\"thread/loaded/list\",\"params\":{\"limit\":100,\"cursor\":\"$loaded_cursor\"}}"
    else
      send_ws_text "{\"id\":$id,\"method\":\"thread/loaded/list\",\"params\":{\"limit\":100}}"
    fi
    wait_ws_response "$id" || return 1
    printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || return 1
    if printf '%s' "$WS_RESPONSE" \
      | grep -Eq '"data"[[:space:]]*:[[:space:]]*\[[^]]*"'"$conversation"'"'; then
      return 0
    fi
    loaded_response=$(cio_temp_file)
    printf '%s\n' "$WS_RESPONSE" | cio_atomic_write "$loaded_response"
    loaded_next=$(cio_json_string nextCursor "$loaded_response")
    /bin/rm -f "$loaded_response"
    [ -n "$loaded_next" ] && [ "${#loaded_next}" -le 512 ] || return 1
    case "$loaded_next" in *[!A-Za-z0-9._:/=+-]*) return 1 ;; esac
    case "|$loaded_seen|" in *"|$loaded_next|"*) return 1 ;; esac
    loaded_seen=${loaded_seen:+$loaded_seen|}$loaded_next
    loaded_cursor=$loaded_next
  done
  return 1
}

codex_require_owned_terminal_process_id() {
  terminal_cursor=
  terminal_seen=
  terminal_pages=0
  terminal_count=0
  codex_terminal_process_id=
  while [ "$terminal_pages" -lt 100 ]; do
    terminal_pages=$((terminal_pages + 1))
    id=$((id + 1))
    if [ -n "$terminal_cursor" ]; then
      send_ws_text "{\"id\":$id,\"method\":\"thread/backgroundTerminals/list\",\"params\":{\"threadId\":\"$conversation\",\"limit\":100,\"cursor\":\"$terminal_cursor\"}}"
    else
      send_ws_text "{\"id\":$id,\"method\":\"thread/backgroundTerminals/list\",\"params\":{\"threadId\":\"$conversation\",\"limit\":100}}"
    fi
    wait_ws_response "$id" || return 1
    printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || return 1
    terminal_page_count=$(printf '%s' "$WS_RESPONSE" | awk '
    { text = text $0 }
    END {
      count = 0
      while (match(text, /"processId"[[:space:]]*:/)) {
        count++
        text = substr(text, RSTART + RLENGTH)
      }
      print count
    }
  ')
    case "$terminal_page_count" in ''|*[!0-9]*) return 1 ;; esac
    terminal_count=$((terminal_count + terminal_page_count))
    [ "$terminal_count" -le 1 ] || return 1
    if [ "$terminal_page_count" = 1 ]; then
      codex_terminal_process_id=$(printf '%s' "$WS_RESPONSE" \
        | sed -n 's/.*"processId"[[:space:]]*:[[:space:]]*"\([1-9][0-9]\{0,8\}\)".*/\1/p')
      [ -n "$codex_terminal_process_id" ] || return 1
    fi
    terminal_response=$(cio_temp_file)
    printf '%s\n' "$WS_RESPONSE" | cio_atomic_write "$terminal_response"
    terminal_next=$(cio_json_string nextCursor "$terminal_response")
    /bin/rm -f "$terminal_response"
    if [ -z "$terminal_next" ]; then
      if [ "$terminal_count" = 1 ] && [ -n "$codex_terminal_process_id" ]; then return 0; fi
      return 1
    fi
    [ "${#terminal_next}" -le 512 ] || return 1
    case "$terminal_next" in *[!A-Za-z0-9._:/=+-]*) return 1 ;; esac
    case "|$terminal_seen|" in *"|$terminal_next|"*) return 1 ;; esac
    terminal_seen=${terminal_seen:+$terminal_seen|}$terminal_next
    terminal_cursor=$terminal_next
  done
  return 1
}

codex_thread_session_id() {
  thread_session_id=$(printf '%s' "$WS_RESPONSE" \
    | sed -n 's/.*"sessionId"[[:space:]]*:[[:space:]]*"\([0-9A-Fa-f-]*\)".*/\1/p')
  printf '%s' "$thread_session_id" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[89AaBb][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$' || return 1
  printf '%s\n' "$thread_session_id"
}

codex_preflight_probe() (
  if ! codex_socket_reason; then return 0; fi
  command -v codex >/dev/null 2>&1 || { printf '%s\n' app_server_unavailable; return; }
  app_dir=$(cio_state_root)/codex-preflight-$$-$(openssl rand -hex 8)
  cio_make_private_dir "$app_dir"
  input=$app_dir/in output=$app_dir/out
  mkfifo "$input" "$output"
  if ! codex_socket_reason >/dev/null; then
    socket_reason=$(codex_socket_reason 2>/dev/null || true)
    /bin/rm -f "$input" "$output"
    /bin/rmdir "$app_dir" 2>/dev/null || true
    printf '%s\n' "$socket_reason"
    return
  fi
  expected_socket_device=$codex_socket_device
  expected_socket_inode=$codex_socket_inode
  codex app-server proxy --sock "$codex_socket" <"$input" >"$output" 2>/dev/null & proxy=$!
  start_preflight_watchdog() {
    watchdog_ticks=$1
    (
      trap 'exit 0' TERM
      timeout_ticks=0
      while [ "$timeout_ticks" -lt "$watchdog_ticks" ]; do
        /bin/sleep 0.1
        timeout_ticks=$((timeout_ticks + 1))
      done
      kill -TERM "$proxy" 2>/dev/null || exit 0
      timeout_ticks=0
      while [ "$timeout_ticks" -lt 10 ]; do
        /bin/sleep 0.1
        timeout_ticks=$((timeout_ticks + 1))
      done
      kill -KILL "$proxy" 2>/dev/null || true
    ) </dev/null >/dev/null 2>&1 & proxy_watchdog=$!
  }
  stop_preflight_watchdog() {
    kill -TERM "$proxy_watchdog" 2>/dev/null || true
    wait "$proxy_watchdog" 2>/dev/null || true
  }
  # Fail a wedged connection quickly, then allow the bounded multi-request
  # ownership probe enough time to traverse loaded-thread pages.
  start_preflight_watchdog 50
  cleanup_preflight_proxy() {
    trap - EXIT HUP INT TERM
    stop_preflight_watchdog
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    kill -TERM "$proxy" 2>/dev/null || true
    proxy_stop_attempts=0
    while kill -0 "$proxy" 2>/dev/null; do
      proxy_state=$(/bin/ps -p "$proxy" -o state= 2>/dev/null || true)
      case "$proxy_state" in ''|*Z*) break ;; esac
      proxy_stop_attempts=$((proxy_stop_attempts + 1))
      if [ "$proxy_stop_attempts" -ge 10 ]; then
        kill -KILL "$proxy" 2>/dev/null || true
        break
      fi
      /bin/sleep 0.1
    done
    wait "$proxy" 2>/dev/null || true
    /bin/rm -f "$input" "$output"
    /bin/rmdir "$app_dir" 2>/dev/null || true
  }
  trap cleanup_preflight_proxy EXIT
  trap 'cleanup_preflight_proxy; exit 129' HUP
  trap 'cleanup_preflight_proxy; exit 130' INT
  trap 'cleanup_preflight_proxy; exit 143' TERM
  exec 3>"$input"
  exec 4<"$output"
  key=$(openssl rand -base64 16 | tr -d '\n')
  expected=$(printf '%s' "${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" | openssl dgst -sha1 -binary | openssl base64 | tr -d '\n')
  printf 'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' "$key" >&3
  cr=$(printf '\r')
  if ! IFS= read -r status <&4; then printf '%s\n' app_server_unavailable; return; fi
  status=${status%"$cr"}
  if [ "$status" != 'HTTP/1.1 101 Switching Protocols' ]; then printf '%s\n' app_server_unavailable; return; fi
  accepted=
  while IFS= read -r line <&4; do
    line=${line%"$cr"}
    [ -n "$line" ] || break
    case "$line" in
      [Ss][Ee][Cc]-[Ww][Ee][Bb][Ss][Oo][Cc][Kk][Ee][Tt]-[Aa][Cc][Cc][Ee][Pp][Tt]:*) accepted=${line#*: } ;;
    esac
  done
  if [ "$accepted" != "$expected" ]; then printf '%s\n' app_server_unavailable; return; fi
  stop_preflight_watchdog
  start_preflight_watchdog 300
  send_ws_text '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"comment_io_plugin","title":"Comment.io plugin","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}'
  if ! wait_ws_response 1 || ! printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:'; then
    printf '%s\n' app_server_unavailable
    return
  fi
  send_ws_text '{"method":"initialized","params":{}}'
  id=1
  if ! codex_require_loaded_thread; then
    printf '%s\n' thread_unavailable
    return
  fi
  id=$((id + 1))
  send_ws_text "{\"id\":$id,\"method\":\"thread/read\",\"params\":{\"threadId\":\"$conversation\",\"includeTurns\":false}}"
  if ! wait_ws_response "$id" || ! printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:'; then
    printf '%s\n' thread_unavailable
    return
  fi
  if ! printf '%s' "$WS_RESPONSE" | grep -Fq "\"id\":\"$conversation\""; then
    printf '%s\n' thread_unavailable
    return
  fi
  thread_session_id=$(codex_thread_session_id) || { printf '%s\n' thread_unavailable; return; }
  # A bind is initiated from the ambient turn, where direct input is
  # transiently unavailable. Prove that the shared server owns the exact
  # loaded runner here; inject_codex waits for that runner to become idle.
  id=$((id + 1))
  send_ws_text "{\"id\":$id,\"method\":\"thread/resume\",\"params\":{\"threadId\":\"$conversation\",\"excludeTurns\":true}}"
  if ! wait_ws_response "$id" || ! printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:'; then
    printf '%s\n' thread_ineligible
    return
  fi
  if ! printf '%s' "$WS_RESPONSE" | grep -Fq "\"id\":\"$conversation\""; then
    printf '%s\n' thread_ineligible
    return
  fi
  resumed_thread_session_id=$(codex_thread_session_id) || { printf '%s\n' thread_ineligible; return; }
  [ "$resumed_thread_session_id" = "$thread_session_id" ] || { printf '%s\n' thread_ineligible; return; }
  if ! codex_require_owned_terminal_process_id; then
    printf '%s\n' runner_absent
    return
  fi
  runner_process_id=$codex_terminal_process_id
  if ! codex_socket_reason >/dev/null \
    || [ "$codex_socket_device" != "$expected_socket_device" ] \
    || [ "$codex_socket_inode" != "$expected_socket_inode" ]; then
    printf '%s\n' app_server_unavailable
    return
  fi
  printf 'ready:%s:%s:%s:%s\n' "$expected_socket_device" "$expected_socket_inode" "$thread_session_id" "$runner_process_id"
)

codex_preflight() {
  if ! socket_reason=$(codex_socket_reason); then printf '%s\n' "$socket_reason"; return; fi
  result=$(cio_temp_file)
  "$listener_dir/listener.sh" codex-preflight-probe "$origin" >"$result" 2>/dev/null & probe_pid=$!
  set +e
  wait "$probe_pid"
  probe_rc=$?
  set -e
  if [ "$probe_rc" -eq 0 ] && cio_validate_file "$result"; then
    probe_result=$(sed -n '1p' "$result")
  else
    probe_result=
  fi
  /bin/rm -f "$result"
  case "$probe_result" in
    ready:[0-9]*:[0-9]*:[0-9A-Fa-f-]*:[1-9][0-9]*|app_server_absent|app_server_untrusted|app_server_unavailable|thread_unavailable|thread_ineligible|runner_absent) printf '%s\n' "$probe_result" ;;
    *) printf '%s\n' app_server_unavailable ;;
  esac
}

codex_listener_state() {
  if ! codex_socket_reason; then
    return
  fi
  if load_codex_binding_identity; then
    if [ "$codex_socket_device" != "$bound_socket_device" ] \
      || [ "$codex_socket_inode" != "$bound_socket_inode" ]; then
      printf '%s\n' app_server_changed
      return
    fi
  fi
  if owned_process "$binding.pid" codex-wait; then printf '%s\n' ready
  else printf '%s\n' watcher_absent
  fi
}

socket_wait() {
  load_binding || return 1
  response=$(cio_temp_file)
  json=$(printf '{"plugin_session_id":"%s","binding_generation":%s}' "$session" "$generation")
  if ! code=$(cio_post_json "$identity" "$origin" /agents/me/notifications/plugin-session/socket-ticket "$json" "$response"); then /bin/rm -f "$response"; return 75; fi
  if [ "$code" != 201 ]; then
    /bin/rm -f "$response"
    case "$code" in 429|5??) return 75 ;; *) return 1 ;; esac
  fi
  ticket=$(cio_json_string socket_ticket "$response")
  /bin/rm -f "$response"
  case "$ticket" in pst_*) ;; *) return 1 ;; esac

  host=${origin#https://}
  case "$host" in *:*) connect=$host; server=${host%%:*} ;; *) connect=$host:443; server=$host ;; esac
  session_dir=$cio_state/socket-$(cio_hash "$conversation")-$$
  cio_make_private_dir "$session_dir"
  input=$session_dir/in output=$session_dir/out
  mkfifo "$input" "$output"
  # Hold both FIFO pairs open while the TLS child and endpoint monitor start.
  # If endpoint loss kills the child before its redirections finish, these
  # keepers prevent the parent from blocking forever while opening fd 3 or 4.
  exec 5<>"$input"; exec 6<>"$output"
  openssl s_client -quiet -connect "$connect" -servername "$server" \
    -verify_hostname "$server" -verify_return_error <"$input" >"$output" 2>/dev/null 5>&- 6>&- &
  tls_pid=$!
  monitor_pid=
  if [ "$cio_host" = codex ]; then
    codex_socket=${CODEX_HOME:-$HOME/.codex}/app-server-control/app-server-control.sock
    watcher_pid=$$
    watcher_nonce=$owner_nonce
    (
      exec 5>&-; exec 6>&-
      while binding_current "$session" "$generation" \
        && codex_bound_endpoint_current \
        && owned_process "$binding.pid" codex-wait \
        && [ "$process_pid" = "$watcher_pid" ] \
        && [ "$process_nonce" = "$watcher_nonce" ]; do /bin/sleep 2; done
      kill -TERM "$tls_pid" 2>/dev/null || true
    ) &
    monitor_pid=$!
  fi
  cleanup_socket() {
    trap - EXIT HUP INT TERM
    kill -TERM "$tls_pid" 2>/dev/null || true
    wait "$tls_pid" 2>/dev/null || true
    if [ -n "$monitor_pid" ]; then kill -TERM "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; fi
    exec 3>&- 2>/dev/null || true; exec 4<&- 2>/dev/null || true
    exec 5>&- 2>/dev/null || true; exec 6>&- 2>/dev/null || true
    /bin/rm -f "$input" "$output"; /bin/rmdir "$session_dir" 2>/dev/null || true
  }
  trap cleanup_socket EXIT
  trap 'cleanup_socket; exit 129' HUP
  trap 'cleanup_socket; exit 130' INT
  trap 'cleanup_socket; exit 143' TERM
  exec 3>"$input"; exec 4<"$output"
  exec 5>&-; exec 6>&-
  websocket_key=$(openssl rand -base64 16 | tr -d '\n')
  expected=$(printf '%s' "${websocket_key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" | openssl dgst -sha1 -binary | openssl base64 | tr -d '\n')
  request_path="/agents/me/notifications/connect?client=plugin&delivery_contract=plugin_session_v1&plugin_session_id=$session&binding_generation=$generation"
  printf 'GET %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' \
    "$request_path" "$server" "$ticket" "$websocket_key" >&3
  ticket=
  cr=$(printf '\r')
  if ! IFS= read -r status <&4; then cleanup_socket; trap - EXIT HUP INT TERM; return 75; fi
  status=${status%"$cr"}
  if [ "$status" != 'HTTP/1.1 101 Switching Protocols' ]; then cleanup_socket; trap - EXIT HUP INT TERM; return 75; fi
  accepted=
  while IFS= read -r line <&4; do
    line=${line%"$cr"}; [ -n "$line" ] || break
    case "$line" in [Ss][Ee][Cc]-[Ww][Ee][Bb][Ss][Oo][Cc][Kk][Ee][Tt]-[Aa][Cc][Cc][Ee][Pp][Tt]:*) accepted=${line#*: } ;; esac
  done
  if [ "$accepted" != "$expected" ]; then cleanup_socket; trap - EXIT HUP INT TERM; return 75; fi
  send_ws_text '{"type":"ping"}'
  while binding_current "$session" "$generation"; do
    if read_ws_text; then
      frame=$(cio_temp_file); printf '%s\n' "$WS_MESSAGE" | cio_atomic_write "$frame"
      locator=$(cio_json_string agent_interaction_locator_id "$frame")
      connection=$(cio_json_string plugin_connection_id "$frame")
      /bin/rm -f "$frame"
      if [ -n "$locator" ] && [ -n "$connection" ]; then
        response=$(cio_temp_file)
        set +e
        pickup_canonical "$locator" "$connection" "$response"
        pickup_rc=$?
        set -e
        if [ "$pickup_rc" -eq 0 ] && binding_current "$session" "$generation"; then
          /bin/rm -f "$response"
          cleanup_socket
          trap - EXIT HUP INT TERM
          return 0
        fi
        /bin/rm -f "$response"
        if [ "$pickup_rc" -eq 75 ]; then
          cleanup_socket
          trap - EXIT HUP INT TERM
          return 75
        fi
      else
        response=$(cio_temp_file)
        set +e
        lease_ordinary "$response"
        lease_rc=$?
        set -e
        if [ "$lease_rc" -eq 0 ] && binding_current "$session" "$generation"; then
          /bin/rm -f "$response"
          cleanup_socket
          trap - EXIT HUP INT TERM
          return 0
        fi
        /bin/rm -f "$response"
        if [ "$lease_rc" -eq 75 ]; then
          cleanup_socket
          trap - EXIT HUP INT TERM
          return 75
        fi
      fi
    else
      frame_rc=$?
      if [ "$frame_rc" -eq 2 ] && send_ws_pong "$WS_MESSAGE"; then :
      else cleanup_socket; trap - EXIT HUP INT TERM; return 75
      fi
    fi
  done
  cleanup_socket
  trap - EXIT HUP INT TERM
  return 1
}

inject_codex() (
  load_codex_binding_identity || return 1
  codex_bound_endpoint_current || return 1
  socket=$codex_socket
  app_dir=$(cio_state_root)/codex-proxy-$$
  cio_make_private_dir "$app_dir"
  input=$app_dir/in output=$app_dir/out
  mkfifo "$input" "$output"
  if ! codex_bound_endpoint_current; then
    /bin/rm -f "$input" "$output"
    /bin/rmdir "$app_dir" 2>/dev/null || true
    return 1
  fi
  codex app-server proxy --sock "$socket" <"$input" >"$output" 2>/dev/null & proxy=$!
  watcher_pid=$$
  watcher_nonce=$owner_nonce
  (
    while binding_current "$session" "$generation" \
      && owned_process "$binding.pid" codex-wait \
      && [ "$process_pid" = "$watcher_pid" ] \
      && [ "$process_nonce" = "$watcher_nonce" ]; do /bin/sleep 2; done
    kill -TERM "$proxy" 2>/dev/null || true
  ) & proxy_monitor=$!
  cleanup_proxy() {
    trap - EXIT HUP INT TERM
    kill -TERM "$proxy" 2>/dev/null || true; wait "$proxy" 2>/dev/null || true
    kill -TERM "$proxy_monitor" 2>/dev/null || true; wait "$proxy_monitor" 2>/dev/null || true
    exec 3>&- 2>/dev/null || true; exec 4<&- 2>/dev/null || true
    /bin/rm -f "$input" "$output"; /bin/rmdir "$app_dir" 2>/dev/null || true
  }
  trap cleanup_proxy EXIT
  trap 'cleanup_proxy; exit 129' HUP
  trap 'cleanup_proxy; exit 130' INT
  trap 'cleanup_proxy; exit 143' TERM
  exec 3>"$input"; exec 4<"$output"
  key=$(openssl rand -base64 16 | tr -d '\n')
  expected=$(printf '%s' "${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" | openssl dgst -sha1 -binary | openssl base64 | tr -d '\n')
  printf 'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' "$key" >&3
  cr=$(printf '\r'); IFS= read -r status <&4 || return 1; status=${status%"$cr"}; [ "$status" = 'HTTP/1.1 101 Switching Protocols' ] || return 1
  accepted=; while IFS= read -r line <&4; do line=${line%"$cr"}; [ -n "$line" ] || break; case "$line" in [Ss][Ee][Cc]-[Ww][Ee][Bb][Ss][Oo][Cc][Kk][Ee][Tt]-[Aa][Cc][Cc][Ee][Pp][Tt]:*) accepted=${line#*: };; esac; done
  [ "$accepted" = "$expected" ] || return 1
  codex_bound_endpoint_current || return 1
  send_ws_text '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"comment_io_plugin","title":"Comment.io plugin","version":"1.0.0"},"capabilities":{"experimentalApi":true}}}'
  wait_ws_response 1 || return 1
  printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || return 1
  send_ws_text '{"method":"initialized","params":{}}'
  id=1
  codex_require_loaded_thread || return 1
  id=$((id + 1))
  send_ws_text "{\"id\":$id,\"method\":\"thread/resume\",\"params\":{\"threadId\":\"$conversation\",\"excludeTurns\":true}}"
  wait_ws_response "$id" || return 1
  printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || return 1
  printf '%s' "$WS_RESPONSE" | grep -Fq "\"id\":\"$conversation\"" || return 1
  resumed_thread_session_id=$(codex_thread_session_id) || return 1
  [ "$resumed_thread_session_id" = "$bound_thread_session_id" ] || return 1
  last_renew=$(date +%s)
  while binding_current "$session" "$generation"; do
    id=$((id + 1))
    send_ws_text "{\"id\":$id,\"method\":\"thread/read\",\"params\":{\"threadId\":\"$conversation\",\"includeTurns\":false}}"
    wait_ws_response "$id" || return 1
    printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || return 1
    # thread/read must describe the exact ambient conversation. A neighboring
    # loaded thread is never an acceptable substitute, even when it is idle.
    printf '%s' "$WS_RESPONSE" | grep -Fq "\"id\":\"$conversation\"" || return 1
    current_thread_session_id=$(codex_thread_session_id) || return 1
    [ "$current_thread_session_id" = "$bound_thread_session_id" ] || return 1
    if printf '%s' "$WS_RESPONSE" | grep -q '"status":{"type":"idle"' && printf '%s' "$WS_RESPONSE" | grep -q '"canAcceptDirectInput":true'; then break; fi
    now=$(date +%s)
    if [ "$((now - last_renew))" -ge 20 ]; then
      attempt=$(attempt_file)
      if cio_validate_file "$attempt"; then
        renew_op=$(operation_id); renew_response=$(cio_temp_file)
        case "$(cio_field "$attempt" kind)" in
          work)
            /bin/rm -f "$renew_response"
            last_renew=$now
            continue
            ;;
          ordinary)
            claim=$(cio_field "$attempt" claim_id)
            renew_code=$(cio_post_json "$identity" "$origin" "/agents/me/notifications/claim/$claim/renew" "{\"op_id\":\"$renew_op\"}" "$renew_response" "$renew_op") || return 1
            ;;
          canonical)
            locator=$(cio_field "$attempt" locator_id); claimant=$(cio_field "$attempt" claimant_id)
            renew_json=$(printf '{"claimant_id":"%s","operation_id":"%s"}' "$claimant" "$renew_op")
            renew_code=$(cio_post_json "$identity" "$origin" "/agents/me/agent-interactions/$locator/activity" "$renew_json" "$renew_response" "$renew_op") || return 1
            ;;
          *) /bin/rm -f "$renew_response"; return 1 ;;
        esac
        /bin/rm -f "$renew_response"
        [ "$renew_code" = 200 ] || return 1
      fi
      last_renew=$now
    fi
    /bin/sleep 0.1
  done
  binding_current "$session" "$generation" || return 1
  codex_bound_endpoint_current || return 1
  codex_require_loaded_thread || return 1
  codex_bound_endpoint_current || return 1
  id=$((id + 1))
  send_ws_text "{\"id\":$id,\"method\":\"thread/read\",\"params\":{\"threadId\":\"$conversation\",\"includeTurns\":false}}"
  wait_ws_response "$id" || return 1
  printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || return 1
  printf '%s' "$WS_RESPONSE" | grep -Fq "\"id\":\"$conversation\"" || return 1
  current_thread_session_id=$(codex_thread_session_id) || return 1
  [ "$current_thread_session_id" = "$bound_thread_session_id" ] || return 1
  printf '%s' "$WS_RESPONSE" | grep -q '"status":{"type":"idle"' || return 1
  printf '%s' "$WS_RESPONSE" | grep -q '"canAcceptDirectInput":true' || return 1
  if work_wake_binding; then
    owned_process "$binding.pid" codex-wait \
      && [ "$process_nonce" = "$owner_nonce" ] || return 1
    client=comment-io-$(openssl rand -hex 12); id=$((id + 1))
    send_ws_text "{\"id\":$id,\"method\":\"turn/start\",\"params\":{\"threadId\":\"$conversation\",\"clientUserMessageId\":\"$client\",\"input\":[{\"type\":\"text\",\"text\":\"You have a Comment.io notification. Call receive.\",\"textElements\":[]}]}}"
    WS_RESPONSE=
    wait_ws_response "$id" || true
    while binding_current "$session" "$generation"; do
      id=$((id + 1))
      send_ws_text "{\"id\":$id,\"method\":\"thread/read\",\"params\":{\"threadId\":\"$conversation\",\"includeTurns\":false}}"
      wait_ws_response "$id" || break
      printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:' || break
      printf '%s' "$WS_RESPONSE" | grep -Fq "\"id\":\"$conversation\"" || break
      current_thread_session_id=$(codex_thread_session_id) || break
      [ "$current_thread_session_id" = "$bound_thread_session_id" ] || break
      if printf '%s' "$WS_RESPONSE" | grep -q '"status":{"type":"idle"' \
        && printf '%s' "$WS_RESPONSE" | grep -q '"canAcceptDirectInput":true'; then
        break
      fi
      /bin/sleep 0.1
    done
    cleanup_proxy
    trap - EXIT HUP INT TERM
    return 0
  fi
  attempt=$(attempt_file)
  cio_validate_file "$attempt" || return 1
  validation_op=
  case "$(cio_field "$attempt" kind)" in
    ordinary)
      claim=$(cio_field "$attempt" claim_id)
      validation_route=/agents/me/notifications/plugin-session/claim/revalidate
      json=$(printf '{"plugin_session_id":"%s","binding_generation":%s,"claim_id":"%s"}' "$session" "$generation" "$claim")
      ;;
    canonical)
      locator=$(cio_field "$attempt" locator_id); claimant=$(cio_field "$attempt" claimant_id)
      cio_safe_id "$locator" 80 && cio_safe_id "$claimant" 80 || return 1
      validation_op=$(operation_id)
      validation_route=/agents/me/agent-interactions/$locator/activity
      json=$(printf '{"claimant_id":"%s","operation_id":"%s"}' "$claimant" "$validation_op")
      ;;
    *) return 1 ;;
  esac
  validation=$(cio_temp_file)
  if [ -n "$validation_op" ]; then
    if ! validation_code=$(cio_post_json "$identity" "$origin" "$validation_route" "$json" "$validation" "$validation_op"); then
      /bin/rm -f "$validation"
      return 1
    fi
  elif ! validation_code=$(cio_post_json "$identity" "$origin" "$validation_route" "$json" "$validation"); then
    /bin/rm -f "$validation"
    return 1
  fi
  /bin/rm -f "$validation"
  [ "$validation_code" = 200 ] || return 1
  binding_current "$session" "$generation" || return 1
  codex_bound_endpoint_current || return 1
  client=comment-io-$(openssl rand -hex 12); id=$((id + 1))
  send_ws_text "{\"id\":$id,\"method\":\"turn/start\",\"params\":{\"threadId\":\"$conversation\",\"clientUserMessageId\":\"$client\",\"input\":[{\"type\":\"text\",\"text\":\"You have a Comment.io notification. Call receive.\",\"textElements\":[]}]}}"
  WS_RESPONSE=
  wait_ws_response "$id" || true
  if ! printf '%s' "$WS_RESPONSE" | grep -q '"result"[[:space:]]*:'; then
    attempt=$(attempt_file)
    if cio_validate_file "$attempt" && [ "$(cio_field "$attempt" kind)" = ordinary ]; then
      if printf '%s' "$WS_RESPONSE" | grep -q '"error"[[:space:]]*:'; then
        release || discard_local_attempt
      else
        claim=$(cio_field "$attempt" claim_id); correlation=codex:$(openssl rand -hex 16); uncertain=$(cio_temp_file)
        json=$(printf '{"plugin_session_id":"%s","binding_generation":%s,"claim_id":"%s","correlation_id":"%s"}' "$session" "$generation" "$claim" "$correlation")
        set +e
        uncertain_code=$(cio_post_json "$identity" "$origin" /agents/me/notifications/plugin-session/submission-uncertain "$json" "$uncertain" 2>/dev/null)
        uncertain_rc=$?
        set -e
        /bin/rm -f "$uncertain"
        if [ "$uncertain_rc" -ne 0 ] || [ "$uncertain_code" = 200 ]; then
          # A transport failure may have happened after the server committed the
          # fence. Preserve the exact correlation locally so the delivered turn
          # can reconcile it and so the outer watcher never releases it as a
          # definite failure.
          cio_atomic_append_field "$attempt" correlation_id "$correlation"
          cio_atomic_append_field "$attempt" uncertain_deadline "$(( $(date +%s) + 125 ))"
        else
          release || discard_local_attempt
        fi
      fi
    elif cio_validate_file "$attempt"; then
      # Canonical interaction delivery has no ordinary submission-correlation
      # endpoint. Preserve the claimed attempt long enough for a possibly
      # delivered turn to receive it, then let the server's bounded activity
      # lease decide whether it can be offered again.
      cio_atomic_append_field "$attempt" uncertain_deadline "$(( $(date +%s) + 125 ))"
    fi
    return 1
  fi
  attempt=$(attempt_file)
  if cio_validate_file "$attempt"; then
    cio_atomic_append_field "$attempt" uncertain_deadline "$(( $(date +%s) + 125 ))"
  fi
  cleanup_proxy; trap - EXIT HUP INT TERM
)

receive() {
  load_binding || cio_die NOT_LISTENING 2
  if work_wake_binding; then
    receive_work
    return
  fi
  attempt=$(attempt_file)
  cio_validate_file "$attempt" || cio_die NO_CLAIMED_WORK 2
  kind=$(cio_field "$attempt" kind)
  payload=$(payload_file)
  cio_validate_file "$payload" || cio_die ATTEMPT_PAYLOAD_MISSING 2
  response=$(cio_temp_file)
  case "$kind" in
    ordinary)
      claim=$(cio_field "$attempt" claim_id)
      cio_safe_id "$claim" 120 || cio_die ATTEMPT_INVALID
      correlation=$(cio_field "$attempt" correlation_id 2>/dev/null || true)
      if [ -n "$correlation" ]; then
        cio_safe_id "$correlation" 128 || cio_die ATTEMPT_INVALID
        notification=$(cio_field "$attempt" notification_id)
        cio_safe_id "$notification" 120 || cio_die ATTEMPT_INVALID
        json=$(printf '{"plugin_session_id":"%s","binding_generation":%s,"claim_id":"%s","correlation_id":"%s"}' "$session" "$generation" "$claim" "$correlation")
        code=$(cio_post_json "$identity" "$origin" /agents/me/notifications/plugin-session/submission-uncertain "$json" "$response") || cio_die SUBMISSION_SETTLEMENT_UNKNOWN 75
        [ "$code" = 200 ] || cio_die SUBMISSION_SETTLEMENT_FAILED 2
        json=$(printf '{"notification_id":"%s","correlation_id":"%s","outcome":"delivered"}' "$notification" "$correlation")
        code=$(cio_post_json "$identity" "$origin" /agents/me/notifications/plugin-session/submission-settle "$json" "$response") || cio_die SUBMISSION_SETTLEMENT_UNKNOWN 75
        [ "$code" = 200 ] || cio_die SUBMISSION_SETTLEMENT_FAILED 2
        cio_atomic_append_field "$attempt" submission_settled delivered
      else
        json=$(printf '{"plugin_session_id":"%s","binding_generation":%s,"claim_id":"%s"}' "$session" "$generation" "$claim")
        code=$(cio_post_json "$identity" "$origin" /agents/me/notifications/plugin-session/claim/revalidate "$json" "$response") || cio_die CLAIM_LOST 2
        [ "$code" = 200 ] || cio_die CLAIM_LOST 2
      fi
      cio_redact <"$payload"
      ;;
    canonical)
      cio_safe_id "$(cio_field "$attempt" locator_id)" 80 || cio_die ATTEMPT_INVALID
      cio_safe_id "$(cio_field "$attempt" claimant_id)" 80 || cio_die ATTEMPT_INVALID
      cio_redact <"$payload"
      ;;
    *) cio_die ATTEMPT_INVALID ;;
  esac
  if [ "$(cio_field "$attempt" submission_received 2>/dev/null || true)" != true ]; then
    cio_atomic_append_field "$attempt" submission_received true
  fi
  /bin/rm -f "$response"
  [ "$(cio_field "$attempt" submission_settled 2>/dev/null || true)" = delivered ] || start_keeper
}

start_keeper() {
  keeper=$(keeper_file)
  owned_process "$keeper" keep && return
  /bin/rm -f "$keeper"
  keeper_nonce=keeper_$(openssl rand -hex 16)
  "$listener_dir/listener.sh" keep "$origin" "$keeper_nonce" >/dev/null 2>&1 &
  printf '%s\n%s\n' "$!" "$keeper_nonce" | cio_atomic_write "$keeper"
}

stop_keeper() {
  keeper=$(keeper_file)
  retire_process_record "$keeper" keep
}

keeper_live() {
  owned_process "$(keeper_file)" keep
}

keep_claim() {
  load_binding || exit 0
  attempt=$(attempt_file)
  cio_validate_file "$attempt" || exit 0
  kind=$(cio_field "$attempt" kind)
  while binding_current "$session" "$generation" && cio_validate_file "$attempt"; do
    /bin/sleep 25
    response=$(cio_temp_file); op=$(operation_id)
    case "$kind" in
      ordinary)
        claim=$(cio_field "$attempt" claim_id)
        cio_safe_id "$claim" 120 || exit 0
        set +e
        code=$(cio_post_json "$identity" "$origin" "/agents/me/notifications/claim/$claim/renew" "{\"op_id\":\"$op\"}" "$response" "$op")
        request_rc=$?
        set -e
        ;;
      canonical)
        locator=$(cio_field "$attempt" locator_id); claimant=$(cio_field "$attempt" claimant_id)
        cio_safe_id "$locator" 80 && cio_safe_id "$claimant" 80 || exit 0
        json=$(printf '{"claimant_id":"%s","operation_id":"%s"}' "$claimant" "$op")
        set +e
        code=$(cio_post_json "$identity" "$origin" "/agents/me/agent-interactions/$locator/activity" "$json" "$response" "$op")
        request_rc=$?
        set -e
        ;;
      *) exit 0 ;;
    esac
    /bin/rm -f "$response"
    if [ "$request_rc" -ne 0 ]; then /bin/sleep 2; continue; fi
    case "$code" in 200) ;; 429|5??) /bin/sleep 2; continue ;; *) exit 0 ;; esac
  done
}

settle() {
  requested_outcome=${3:-}
  op=${4:-}
  reply=${5:-}
  edit=${6:-}
  selected_ids=${7:-}
  if work_wake_binding; then
    complete_work "$selected_ids"
    return
  fi
  attempt=$(attempt_file)
  cio_validate_file "$attempt" || cio_die NO_CLAIMED_WORK 2
  kind=$(cio_field "$attempt" kind)
  response=$(cio_temp_file)
  case "$kind" in
    ordinary)
      claim=$(cio_field "$attempt" claim_id)
      cio_safe_id "$claim" 120 || cio_die ATTEMPT_INVALID
      if [ "$(cio_field "$attempt" submission_settled 2>/dev/null || true)" = delivered ]; then
        code=200
      else
        cio_terminal_operation "$attempt" settle "$op" "ordinary:$claim"
        op=$CIO_TERMINAL_OPERATION
        code=$(cio_post_json "$identity" "$origin" "/agents/me/notifications/claim/$claim/ack" "{\"op_id\":\"$op\"}" "$response" "$op") || cio_die SETTLE_FAILED
      fi
      ;;
    canonical)
      locator=$(cio_field "$attempt" locator_id)
      claimant=$(cio_field "$attempt" claimant_id)
      cio_safe_id "$locator" 80 && cio_safe_id "$claimant" 80 || cio_die ATTEMPT_INVALID
      case "$requested_outcome" in
        replied)
          [ -n "$reply" ] || cio_die REPLY_OPERATION_REQUIRED 64
          cio_safe_id "$reply" 128 || cio_die REPLY_OPERATION_INVALID 64
          ;;
        made_edits)
          [ -n "$edit" ] || cio_die EDIT_OPERATION_REQUIRED 64
          cio_safe_id "$edit" 128 || cio_die EDIT_OPERATION_INVALID 64
          ;;
        replied_and_made_edits)
          [ -n "$reply" ] || cio_die REPLY_OPERATION_REQUIRED 64
          [ -n "$edit" ] || cio_die EDIT_OPERATION_REQUIRED 64
          cio_safe_id "$reply" 128 || cio_die REPLY_OPERATION_INVALID 64
          cio_safe_id "$edit" 128 || cio_die EDIT_OPERATION_INVALID 64
          ;;
        no_action) ;;
        *) cio_die INVALID_OUTCOME 64 ;;
      esac
      cio_terminal_operation "$attempt" settle "$op" "canonical:$locator:$claimant:$requested_outcome:$reply:$edit"
      op=$CIO_TERMINAL_OPERATION
      case "$requested_outcome" in
        replied) json=$(printf '{"claimant_id":"%s","operation_id":"%s","outcome":"replied","reply_operation_id":"%s"}' "$claimant" "$op" "$reply") ;;
        made_edits) json=$(printf '{"claimant_id":"%s","operation_id":"%s","outcome":"made_edits","edit_operation_id":"%s"}' "$claimant" "$op" "$edit") ;;
        replied_and_made_edits) json=$(printf '{"claimant_id":"%s","operation_id":"%s","outcome":"replied_and_made_edits","reply_operation_id":"%s","edit_operation_id":"%s"}' "$claimant" "$op" "$reply" "$edit") ;;
        no_action) json=$(printf '{"claimant_id":"%s","operation_id":"%s","outcome":"no_action"}' "$claimant" "$op") ;;
      esac
      code=$(cio_post_json "$identity" "$origin" "/agents/me/agent-interactions/$locator/settle" "$json" "$response" "$op") || cio_die SETTLE_FAILED
      ;;
    *) cio_die ATTEMPT_INVALID ;;
  esac
  [ "$code" = 200 ] || { cio_redact <"$response" >&2; cio_die SETTLE_FAILED; }
  stop_keeper
  /bin/rm -f "$response" "$attempt" "$(payload_file)"
  printf '%s\n' SETTLED
}

release_file() (
  attempt=$1
  cio_validate_file "$attempt" || cio_die NO_CLAIMED_WORK 2
  [ "$(cio_field "$attempt" origin)" = "$origin" ] || cio_die ATTEMPT_INVALID
  identity=$(cio_field "$attempt" identity)
  cio_validate_file "$identity" || cio_die ATTEMPT_INVALID
  kind=$(cio_field "$attempt" kind)
  response=$(cio_temp_file)
  cleanup_release_response() { /bin/rm -f "$response"; }
  trap cleanup_release_response EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  case "$kind" in
    ordinary)
      claim=$(cio_field "$attempt" claim_id)
      cio_safe_id "$claim" 120 || cio_die ATTEMPT_INVALID
      cio_terminal_operation "$attempt" release '' "ordinary:$claim"
      op=$CIO_TERMINAL_OPERATION
      code=$(cio_post_json "$identity" "$origin" "/agents/me/notifications/claim/$claim/release" "{\"op_id\":\"$op\"}" "$response" "$op") || cio_die RELEASE_FAILED
      ;;
    canonical)
      locator=$(cio_field "$attempt" locator_id); claimant=$(cio_field "$attempt" claimant_id)
      cio_safe_id "$locator" 80 && cio_safe_id "$claimant" 80 || cio_die ATTEMPT_INVALID
      cio_terminal_operation "$attempt" release '' "canonical:$locator:$claimant"
      op=$CIO_TERMINAL_OPERATION
      json=$(printf '{"claimant_id":"%s","operation_id":"%s"}' "$claimant" "$op")
      code=$(cio_post_json "$identity" "$origin" "/agents/me/agent-interactions/$locator/interrupt" "$json" "$response" "$op") || cio_die RELEASE_FAILED
      ;;
    *) cio_die ATTEMPT_INVALID ;;
  esac
  [ "$code" = 200 ] || cio_die RELEASE_FAILED
  /bin/rm -f "$response" "$attempt"
  trap - EXIT HUP INT TERM
)

retry_release_snapshots() {
  origin_key=$(cio_origin_key "$origin")
  for release_snapshot in "$cio_state"/.release."$cio_host"."$origin_key".*; do
    [ -e "$release_snapshot" ] || continue
    cio_validate_file "$release_snapshot" || continue
    release_file "$release_snapshot" >/dev/null 2>&1 || true
  done
}

release() {
  if work_wake_binding; then
    release_work
    return
  fi
  attempt=$(attempt_file)
  release_file "$attempt"
  stop_keeper
  /bin/rm -f "$(payload_file)"
  printf '%s\n' RELEASED
}

local_stop() {
  load_binding || exit 0
  stop_keeper
}

codex_arm() {
  load_codex_binding_identity || cio_die LISTEN_BIND_FAILED
  codex_bound_identity_current || return 1
  pid_file=$binding.pid
  owned_process "$pid_file" codex-wait && return
  /bin/rm -f "$pid_file"
  watcher_nonce=watcher_$(openssl rand -hex 16)
  if [ -x /usr/bin/setsid ]; then
    /usr/bin/setsid "$listener_dir/listener.sh" codex-wait "$origin" "$watcher_nonce" >/dev/null 2>&1 &
  elif [ -x /usr/bin/perl ]; then
    /usr/bin/perl -e 'use POSIX qw(setsid); POSIX::setsid(); exec { $ARGV[0] } @ARGV' -- \
      "$listener_dir/listener.sh" codex-wait "$origin" "$watcher_nonce" >/dev/null 2>&1 &
  elif [ -x /usr/bin/nohup ]; then
    /usr/bin/nohup "$listener_dir/listener.sh" codex-wait "$origin" "$watcher_nonce" >/dev/null 2>&1 &
  else
    "$listener_dir/listener.sh" codex-wait "$origin" "$watcher_nonce" >/dev/null 2>&1 &
  fi
  launch_pid=$!
  arm_attempts=0
  watcher_pid=
  until [ -n "$watcher_pid" ]; do
    arm_attempts=$((arm_attempts + 1))
    watcher_pid=$(/bin/ps -ww -eo pid=,args= | awk -v n="$watcher_nonce" '
      $2 ~ /(^|\/)setsid$/ { next }
      $2 ~ /(^|\/)awk$/ { next }
      {
        for (i = 2; i < NF; i++) {
          if ($i ~ /\/listener\.sh$/ && $(i + 1) == "codex-wait" && $0 ~ n) {
            print $1
            exit
          }
        }
      }
    ')
    if [ -n "$watcher_pid" ]; then break; fi
    if [ "$arm_attempts" -ge 50 ]; then
      term_group "$launch_pid"
      /bin/rm -f "$pid_file"
      cio_die LISTENER_START_FAILED
    fi
    /bin/sleep 0.1
  done
  printf '%s\n%s\n' "$watcher_pid" "$watcher_nonce" | cio_atomic_write "$pid_file"
  arm_attempts=0
  until owned_process "$pid_file" codex-wait \
    && [ "$process_pid" = "$watcher_pid" ] \
    && [ "$process_nonce" = "$watcher_nonce" ]; do
    arm_attempts=$((arm_attempts + 1))
    if [ "$arm_attempts" -ge 50 ] || ! kill -0 "$watcher_pid" 2>/dev/null; then
      term_group "$watcher_pid"
      /bin/rm -f "$pid_file"
      cio_die LISTENER_START_FAILED
    fi
    /bin/sleep 0.1
  done
}

codex_disarm() {
  pid_file=$binding.pid
  retire_process_record "$pid_file" codex-wait
}

codex_wait() {
  retry_release_snapshots
  load_codex_binding_identity || exit 0
  pid_file=$binding.pid
  owns_watcher_record() {
    owned_process "$pid_file" codex-wait \
      && [ "$process_pid" = "$$" ] \
      && [ "$process_nonce" = "$owner_nonce" ]
  }
  cleanup_codex_wait() {
    if owns_watcher_record; then /bin/rm -f "$pid_file"; fi
    trap - EXIT HUP INT TERM
    exit 0
  }
  trap '' HUP
  trap cleanup_codex_wait EXIT INT TERM
  startup_attempts=0
  until owns_watcher_record; do
    startup_attempts=$((startup_attempts + 1))
    [ "$startup_attempts" -lt 50 ] || exit 0
    /bin/sleep 0.1
  done
  while binding_current "$session" "$generation" && owns_watcher_record; do
    if [ "$cio_host" = codex ] && ! codex_bound_endpoint_current; then exit 0; fi
    attempt=$(attempt_file)
    if cio_validate_file "$attempt"; then
      if [ "$(cio_field "$attempt" kind 2>/dev/null || true)" = work ]; then
        /bin/sleep 1
        continue
      fi
      if keeper_live; then
        if [ "$(cio_field "$attempt" submission_received 2>/dev/null || true)" != true ]; then
          cio_atomic_append_field "$attempt" submission_received true
        fi
        /bin/sleep 1
        continue
      fi
      if [ "$(cio_field "$attempt" submission_settled 2>/dev/null || true)" = delivered ] \
        || [ "$(cio_field "$attempt" submission_received 2>/dev/null || true)" = true ]; then
        /bin/sleep 1
        continue
      fi
      deadline=$(cio_field "$attempt" uncertain_deadline 2>/dev/null || true)
      case "$deadline" in
        ''|*[!0-9]*)
          cio_atomic_append_field "$attempt" uncertain_deadline "$(( $(date +%s) + 125 ))"
          /bin/sleep 1
          continue
          ;;
        *)
          if [ "$(date +%s)" -ge "$deadline" ]; then discard_local_attempt; else /bin/sleep 1; fi
          continue
          ;;
      esac
    fi
    if work_wake_binding; then
      set +e; work_wake_wait; socket_rc=$?; set -e
      trap '' HUP
      trap cleanup_codex_wait EXIT INT TERM
      if [ "$socket_rc" -eq 0 ] && work_wake_binding; then
        if ! inject_codex; then
          load_codex_binding_identity || exit 0
          [ "$cio_host" != codex ] || codex_bound_endpoint_current || exit 0
        fi
      elif [ "$socket_rc" -eq 75 ]; then
        /bin/sleep 2
      else
        exit 0
      fi
    elif socket_wait && binding_current "$session" "$generation"; then
      if ! inject_codex; then
        attempt=$(attempt_file)
        if cio_validate_file "$attempt" && [ -z "$(cio_field "$attempt" correlation_id 2>/dev/null || true)" ]; then
          release >/dev/null 2>&1 || discard_local_attempt
        fi
        load_codex_binding_identity || exit 0
        [ "$cio_host" != codex ] || codex_bound_endpoint_current || exit 0
      fi
    else
      /bin/sleep 1
    fi
  done
}

work_wake_wait() {
  load_binding || return 1
  work_wake_binding || return 1
  response=$(cio_temp_file)
  owner=$(cio_field "$identity" owner_agent_id 2>/dev/null || true)
  grant=$(cio_field "$identity" grant_id 2>/dev/null || true)
  revocation=$(cio_field "$identity" grant_revocation_generation 2>/dev/null || true)
  if [ -n "$owner" ] && [ -n "$grant" ] && [ -n "$revocation" ]; then
    json=$(printf '{"binding_generation":%s,"owner_agent_id":"%s","grant_id":"%s","grant_revocation_generation":%s}' \
      "$generation" "$owner" "$grant" "$revocation")
  else
    json=$(printf '{"binding_generation":%s}' "$generation")
  fi
  if ! code=$(cio_post_json "$identity" "$origin" /agents/me/work/wake/socket-ticket "$json" "$response"); then
    /bin/rm -f "$response"
    return 75
  fi
  if [ "$code" != 201 ]; then
    /bin/rm -f "$response"
    case "$code" in 429|5??) return 75 ;; *) return 1 ;; esac
  fi
  ticket=$(cio_json_string socket_ticket "$response")
  /bin/rm -f "$response"
  case "$ticket" in wwt_*) ;; *) return 1 ;; esac

  host=${origin#https://}
  case "$host" in *:*) connect=$host; server=${host%%:*} ;; *) connect=$host:443; server=$host ;; esac
  session_dir=$cio_state/socket-$(cio_hash "$conversation")-$$
  cio_make_private_dir "$session_dir"
  input=$session_dir/in output=$session_dir/out
  mkfifo "$input" "$output"
  # Hold both FIFO pairs open while the TLS child and endpoint monitor start.
  # If endpoint loss kills the child before its redirections finish, these
  # keepers prevent the parent from blocking forever while opening fd 3 or 4.
  exec 5<>"$input"; exec 6<>"$output"
  openssl s_client -quiet -connect "$connect" -servername "$server" \
    -verify_hostname "$server" -verify_return_error <"$input" >"$output" 2>/dev/null 5>&- 6>&- &
  tls_pid=$!
  monitor_pid=
  if [ "$cio_host" = codex ]; then
    watcher_pid=$$
    watcher_nonce=$owner_nonce
    (
      exec 5>&-; exec 6>&-
      while work_wake_binding \
        && [ "$(cio_field "$binding" binding_generation 2>/dev/null || true)" = "$generation" ] \
        && codex_bound_endpoint_current \
        && owned_process "$binding.pid" codex-wait \
        && [ "$process_pid" = "$watcher_pid" ] \
        && [ "$process_nonce" = "$watcher_nonce" ]; do /bin/sleep 2; done
      kill -TERM "$tls_pid" 2>/dev/null || true
    ) &
    monitor_pid=$!
  fi
  cleanup_socket() {
    trap - EXIT HUP INT TERM
    kill -TERM "$tls_pid" 2>/dev/null || true
    wait "$tls_pid" 2>/dev/null || true
    if [ -n "$monitor_pid" ]; then kill -TERM "$monitor_pid" 2>/dev/null || true; wait "$monitor_pid" 2>/dev/null || true; fi
    exec 3>&- 2>/dev/null || true; exec 4<&- 2>/dev/null || true
    exec 5>&- 2>/dev/null || true; exec 6>&- 2>/dev/null || true
    /bin/rm -f "$input" "$output"; /bin/rmdir "$session_dir" 2>/dev/null || true
  }
  trap cleanup_socket EXIT
  trap 'cleanup_socket; exit 129' HUP
  trap 'cleanup_socket; exit 130' INT
  trap 'cleanup_socket; exit 143' TERM
  exec 3>"$input"; exec 4<"$output"
  exec 5>&-; exec 6>&-
  websocket_key=$(openssl rand -base64 16 | tr -d '\n')
  expected=$(printf '%s' "${websocket_key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11" | openssl dgst -sha1 -binary | openssl base64 | tr -d '\n')
  request_path="/agents/me/work/wake/connect?delivery_contract=agent_work_wake_v1&binding_generation=$generation"
  printf 'GET %s HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' \
    "$request_path" "$server" "$ticket" "$websocket_key" >&3
  ticket=
  cr=$(printf '\r')
  if ! IFS= read -r status <&4; then cleanup_socket; trap - EXIT HUP INT TERM; return 75; fi
  status=${status%"$cr"}
  if [ "$status" != 'HTTP/1.1 101 Switching Protocols' ]; then cleanup_socket; trap - EXIT HUP INT TERM; return 75; fi
  accepted=
  while IFS= read -r line <&4; do
    line=${line%"$cr"}; [ -n "$line" ] || break
    case "$line" in [Ss][Ee][Cc]-[Ww][Ee][Bb][Ss][Oo][Cc][Kk][Ee][Tt]-[Aa][Cc][Cc][Ee][Pp][Tt]:*) accepted=${line#*: } ;; esac
  done
  if [ "$accepted" != "$expected" ]; then cleanup_socket; trap - EXIT HUP INT TERM; return 75; fi
  send_ws_text '{"type":"ping"}'
  while work_wake_binding && [ "$(cio_field "$binding" binding_generation)" = "$generation" ]; do
    if read_ws_text; then
      frame=$(cio_temp_file); printf '%s\n' "$WS_MESSAGE" | cio_atomic_write "$frame"
      type=$(cio_json_string type "$frame")
      /bin/rm -f "$frame"
      if [ "$type" = displaced ]; then
        cleanup_socket
        trap - EXIT HUP INT TERM
        return 1
      fi
      if [ "$type" = work_pending ]; then
        accept=$(cio_temp_file)
        accept_code=$(cio_post_json "$identity" "$origin" /agents/me/work/wake/accept "$json" "$accept") || accept_code=000
        /bin/rm -f "$accept"
        if [ "$accept_code" != 200 ]; then
          cleanup_socket
          trap - EXIT HUP INT TERM
          return 75
        fi
        if ! set_work_batch_count 0; then
          cleanup_socket
          trap - EXIT HUP INT TERM
          return 1
        fi
        cleanup_socket
        trap - EXIT HUP INT TERM
        return 0
      fi
    else
      cleanup_socket
      trap - EXIT HUP INT TERM
      return 75
    fi
  done
  cleanup_socket
  trap - EXIT HUP INT TERM
  return 1
}

case "$action" in
  claude-hook)
    retry_release_snapshots
    existing_attempt=$(attempt_file)
    if cio_validate_file "$existing_attempt"; then
      if keeper_live || [ "$(cio_field "$existing_attempt" submission_received 2>/dev/null || true)" = true ]; then exit 0; fi
      printf '%s\n' 'Comment.io work is claimed for this exact session.'
      exit 2
    fi
    if load_binding && work_wake_binding; then
      while load_binding && work_wake_binding; do
        set +e; work_wake_wait; socket_rc=$?; set -e
        if [ "$socket_rc" -eq 0 ]; then
          :
          kind=$(cio_field "$binding" activation_kind 2>/dev/null || true)
          agent_id=$(cio_field "$binding" activation_agent_id 2>/dev/null || true)
          handle=$(cio_field "$binding" activation_handle 2>/dev/null || true)
          if [ -n "$kind" ] && [ -n "$agent_id" ] && [ -n "$handle" ]; then
            printf 'activation kind=%s agent_id=%s handle=%s' "$kind" "$agent_id" "$handle"
            grant_id=$(cio_field "$binding" activation_grant_id 2>/dev/null || true)
            owner_agent_id=$(cio_field "$binding" activation_owner_agent_id 2>/dev/null || true)
            grant_revocation_generation=$(cio_field "$binding" activation_grant_revocation_generation 2>/dev/null || true)
            [ -z "$grant_id" ] || printf ' grant_id=%s' "$grant_id"
            [ -z "$owner_agent_id" ] || printf ' owner_agent_id=%s' "$owner_agent_id"
            [ -z "$grant_revocation_generation" ] || printf ' grant_revocation_generation=%s' "$grant_revocation_generation"
            printf '\n'
          fi
          exit 2
        fi
        [ "$socket_rc" -eq 75 ] || exit 0
        /bin/sleep 2
      done
      exit 0
    fi
    while load_binding && binding_current "$session" "$generation"; do
      set +e; socket_wait; socket_rc=$?; set -e
      if [ "$socket_rc" -eq 0 ]; then printf '%s\n' 'Comment.io work is claimed for this exact session.'; exit 2; fi
      [ "$socket_rc" -eq 75 ] || exit 0
      /bin/sleep 2
    done
    exit 0
    ;;
  receive) receive ;;
  settle) load_binding || cio_die NOT_LISTENING 2; settle "$@" ;;
  release) load_binding || cio_die NOT_LISTENING 2; release ;;
  local-stop) local_stop ;;
  keep) keep_claim ;;
  release-snapshot)
    case "${4:-}" in "$cio_state"/.release."$cio_host"."$(cio_origin_key "$origin")".*) release_snapshot=$4 ;; *) cio_die USAGE 64 ;; esac
    release_file "$release_snapshot"
    ;;
  retry-releases) retry_release_snapshots ;;
  codex-arm) codex_arm ;;
  codex-disarm) codex_disarm ;;
  codex-preflight) codex_preflight ;;
  codex-preflight-probe) codex_preflight_probe ;;
  codex-listener-state) codex_listener_state ;;
  codex-wait) codex_wait ;;
  *) cio_die USAGE 64 ;;
esac
