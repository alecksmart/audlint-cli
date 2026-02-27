#!/usr/bin/env bash

kv_get() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | awk -v k="$key" '$0 ~ ("^" k "=") { sub("^[^=]*=", "", $0); print; exit }'
}

is_numeric() {
  [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}
