#!/bin/bash
# Launch one SSH connection in its own terminal window, titled with the name of
# the connection. Called by Panel.qml openConn() (via Quickshell.execDetached).
#
# Usage: launch-ssh-terminal.sh <connection-name> <command> [args...]
#
# Why a wrapper instead of a plain "omarchy-launch-terminal -e <ssh...>":
#   * every call opens a new terminal window, so several sessions can be kept
#     open at the same time;
#   * the window is titled with the connection name.
# Arch's /etc/bash.bashrc (and many other shells) makes the remote shell set its
# own OSC title (user@host:cwd) on every prompt, which would overwrite the
# initial title. foot (the Omarchy default) has a locked-title option, so when
# foot is the default terminal we launch it directly with -T and
# -o locked-title=yes. Other terminals still go through omarchy-launch-terminal
# with --title (best effort); we never touch their configuration.
set -u

name=${1:-SSH}
shift || true
if [ "$#" -eq 0 ]; then
  printf '%s\n' "usage: ${0##*/} <name> <command> [args...]" >&2
  exit 2
fi

# Default terminal chosen by xdg-terminal-exec for this session.
term_id=$(xdg-terminal-exec --print-id 2>/dev/null || true)
case "$term_id" in
foot.desktop*)
  # Same working directory rule as omarchy-launch-terminal: the directory of the
  # active terminal window (falls back to $HOME).
  cwd=$(omarchy-cmd-terminal-cwd 2>/dev/null || true)
  [ -n "$cwd" ] || cwd="$HOME"
  # -T sets the initial title; locked-title stops the remote shell / ssh OSC
  # sequences from replacing it, so the connection name stays for the session.
  exec setsid uwsm-app -- foot \
    -T "$name" \
    -o locked-title=yes \
    --working-directory="$cwd" \
    -e "$@"
  ;;
esac

exec omarchy-launch-terminal --title="$name" -e "$@"
