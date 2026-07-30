#!/usr/bin/env bash
# docker/entrypoint.sh — a cada start do container, descarta a cópia de trabalho anterior e
# copia o repo (montado read-only em /opt/issabel-mineracao-src) fresh pra
# /opt/issabel-mineracao, pra nunca escrever no bind mount original do host.
set -Eeuo pipefail

SRC=/opt/issabel-mineracao-src
DEST=/opt/issabel-mineracao

rm -rf "$DEST"
cp -a "$SRC" "$DEST"

exec "$@"
