#!/usr/bin/env bash
# lib/core/version.sh — `pvx version` / `pvx --version`
core::cmd_version() {
  printf 'pvx %s\n' "$PVX_VERSION"
}
