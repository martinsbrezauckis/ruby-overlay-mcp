#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DESKTOP="${HOME}/Desktop"
NAME="Ruby Overlay"
STATE="party"
HEIGHT="800"
ROTATE="1"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --name)
      NAME="${2:-Ruby Overlay}"
      shift 2
      ;;
    --state)
      STATE="${2:-party}"
      shift 2
      ;;
    --height)
      HEIGHT="${2:-800}"
      shift 2
      ;;
    --no-rotate)
      ROTATE="0"
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

mkdir -p "$DESKTOP"
SAFE_NAME="$(printf '%s' "$NAME" | tr -d ':/')"
[ -n "$SAFE_NAME" ] || SAFE_NAME="Ruby Overlay"
SHORTCUT="${DESKTOP}/${SAFE_NAME}.command"

{
  echo '#!/bin/zsh'
  echo 'set -e'
  printf 'cd %q\n' "$PROJECT_ROOT"
  if [ "$ROTATE" = "1" ]; then
    printf 'nohup %q --height %q --state %q --rotate >/dev/null 2>&1 &\n' "$PROJECT_ROOT/macos/Run-RubyOverlay.command" "$HEIGHT" "$STATE"
  else
    printf 'nohup %q --height %q --state %q >/dev/null 2>&1 &\n' "$PROJECT_ROOT/macos/Run-RubyOverlay.command" "$HEIGHT" "$STATE"
  fi
} > "$SHORTCUT"

chmod +x "$SHORTCUT"
echo "Created desktop shortcut: $SHORTCUT"
