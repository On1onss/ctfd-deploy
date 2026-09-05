#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE="$ROOT_DIR/docker-compose.yml"
MARKER_START="# GENERATED_TASKS_START"
MARKER_END="# GENERATED_TASKS_END"

if [ ! -f "$COMPOSE" ]; then
  echo "error: $COMPOSE not found" >&2
  exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

{
  echo "  $MARKER_START"
  found=0
  for catdir in "$ROOT_DIR"/tasks/*/; do
    [ -d "$catdir" ] || continue
    category="$(basename "$catdir")"
    for dir in "$catdir"*/; do
      [ -d "$dir" ] || continue
      [ -f "$dir/Dockerfile" ] || continue
      [ -f "$dir/challenge.json" ] || continue
      name="$(basename "$dir")"
      service="task-${category}-${name}"
      echo "  $service:"
      echo "    build: ./tasks/$category/$name"
      echo "    restart: unless-stopped"
      echo "    networks:"
      echo "      - proxy"
      found=1
    done
  done
  if [ "$found" -eq 0 ]; then
    echo "  # (нет тасок с Dockerfile)"
  fi
  echo "  $MARKER_END"
} > "$tmp"

python3 - "$COMPOSE" "$tmp" "$MARKER_START" "$MARKER_END" <<'PY'
import sys

compose, gen, start, end = sys.argv[1:5]
with open(compose, encoding="utf-8") as f:
    lines = f.readlines()

start_idx = end_idx = None
for i, line in enumerate(lines):
    if line.strip() == start:
        start_idx = i
    elif line.strip() == end:
        end_idx = i
        break

if start_idx is None or end_idx is None:
    print(f"error: markers '{start}' / '{end}' not found in {compose}", file=sys.stderr)
    sys.exit(1)

with open(gen, encoding="utf-8") as f:
    block = f.read()

with open(compose, "w", encoding="utf-8") as f:
    f.writelines(lines[:start_idx])
    f.write(block)
    f.writelines(lines[end_idx + 1:])
PY

echo "updated $COMPOSE"
grep -c '^  task-' "$COMPOSE" | xargs echo "  task services:"