#!/usr/bin/env bash
# lib/core/help.sh — `pvx help [comando]`
core::cmd_help() {
  if [[ -n ${1:-} ]]; then
    exec "$0" "$1" --help
  fi
  pvx::_print_help
}
