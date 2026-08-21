#!/bin/sh

COMMENT_PLUGIN_HOST=codex
export COMMENT_PLUGIN_HOST

cio_host_label() { printf '%s\n' 'Codex'; }
cio_host_display_name() { printf '%s\n' 'Codex session'; }
cio_open_browser() {
  case "$(uname -s)" in
    Darwin) /usr/bin/open "$1" >/dev/null 2>&1 ;;
    Linux) command -v xdg-open >/dev/null 2>&1 && xdg-open "$1" >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}
cio_host_arm() { "$runtime_dir/listener.sh" codex-arm "$@"; }
cio_host_disarm() { "$runtime_dir/listener.sh" codex-disarm "$@"; }
cio_host_listen_readiness() { "$runtime_dir/listener.sh" codex-preflight "$@"; }
cio_host_listener_state() { "$runtime_dir/listener.sh" codex-listener-state "$@"; }
cio_host_receive() { "$runtime_dir/listener.sh" receive "$1"; }
cio_host_settle() { "$runtime_dir/listener.sh" settle "$@"; }
cio_host_release() { "$runtime_dir/listener.sh" release "$1"; }
cio_host_hook() { "$runtime_dir/listener.sh" codex-hook "$1"; }
