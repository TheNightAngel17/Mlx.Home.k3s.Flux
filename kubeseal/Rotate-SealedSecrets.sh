#!/usr/bin/env bash
#
# Rotates Kubernetes SealedSecrets by generating a fresh controller keypair
# and resealing all application manifests. Mirrors the functionality of
# Rotate-SealedSecrets.ps1 for environments where Bash is preferred.
#
# Usage:
#   ./Rotate-SealedSecrets.sh --env dev \
#       --key /path/to/current/controller.key \
#       [--algorithm RSA4096]
#
#   ./Rotate-SealedSecrets.sh --env prd --clean
#
# Options:
#   --env, -e           Target environment (dev|prd).
#   --key, -k   Path to the existing controller private key (PEM).
#                       Required unless --clean is provided.
#   --algorithm, -a     New key algorithm: RSA2048 | RSA3072 | RSA4096 (default).
#   --clean, -c         Reset staging directories for the environment and exit.
#   --help, -h          Show this help message and exit.
#
# Requirements:
#   - openssl
#   - kubeseal
#   - yq (https://github.com/mikefarah/yq) v4+
#   - realpath (coreutils) or python3/readlink for path resolution
#
set -euo pipefail

usage() {
  sed -n '2,30p' "$0"
  exit 1
}

log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

auto_realpath() {
  local target="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath "$target"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$target" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$target"
  else
    log_error "Unable to resolve absolute paths: realpath, python3, or readlink is required"
    exit 1
  fi
}

relative_path() {
  local base="$1"
  local target="$2"
  if command -v realpath >/dev/null 2>&1; then
    realpath --relative-to="$base" "$target"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$base" "$target" <<'PY'
import os, sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
  else
    log_error "Unable to compute relative paths: realpath or python3 required"
    exit 1
  fi
}

ensure_command() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log_error "Required command '$cmd' not found on PATH"
    exit 1
  fi
}

ensure_directory() {
  local dir="$1"
  mkdir -p "$dir"
}

clean_staging_dirs() {
  local dirs=("$@")
  for dir in "${dirs[@]}"; do
    mkdir -p "$dir"
    if [[ -d "$dir" ]]; then
      find "$dir" -type f ! -name '.gitkeep' -delete
      find "$dir" -mindepth 1 -type d -empty -delete
    fi
  done
}

ENVIRONMENT=""
CURRENT_KEY=""
NEW_ALGO="RSA4096"
CLEAN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)
      [[ $# -ge 2 ]] || usage
      ENVIRONMENT="$2"
      shift 2
      ;;
    -k|--key)
      [[ $# -ge 2 ]] || usage
      CURRENT_KEY="$2"
      shift 2
      ;;
    -a|--algorithm)
      [[ $# -ge 2 ]] || usage
      NEW_ALGO="$2"
      shift 2
      ;;
    -c|--clean)
      CLEAN="true"
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

[[ -n "$ENVIRONMENT" ]] || { log_error "--env is required"; usage; }

case "$ENVIRONMENT" in
  dev|prd) ;;
  *)
    log_error "--env must be 'dev' or 'prd'"
    exit 1
    ;;
esac

if [[ "$CLEAN" == "true" ]]; then
  if [[ -n "$CURRENT_KEY" || "$NEW_ALGO" != "RSA4096" ]]; then
    log_warn "--clean ignores --current-key/--algorithm options"
  fi
else
  [[ -n "$CURRENT_KEY" ]] || { log_error "--current-key is required when not running with --clean"; usage; }
  case "$NEW_ALGO" in
    RSA2048|RSA3072|RSA4096) ;;
    *)
      log_error "--algorithm must be one of RSA2048, RSA3072, RSA4096"
      exit 1
      ;;
  esac
fi

ensure_command openssl
ensure_command kubeseal
ensure_command yq

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(auto_realpath "$SCRIPT_DIR/..")
ENV_ROOT="$SCRIPT_DIR/$ENVIRONMENT"
APPS_ROOT="$REPO_ROOT/apps"

[[ -d "$APPS_ROOT" ]] || { log_error "Apps folder not found at '$APPS_ROOT'"; exit 1; }

ensure_directory "$ENV_ROOT"
STAGE_SEALED="$ENV_ROOT/00_sealed"
STAGE_UNSEALED="$ENV_ROOT/01_unsealed"
STAGE_RESEALED="$ENV_ROOT/02_resealed"
clean_staging_dirs "$STAGE_SEALED" "$STAGE_UNSEALED" "$STAGE_RESEALED"

if [[ "$CLEAN" == "true" ]]; then
  log_info "Staging directories reset for $ENVIRONMENT"
  exit 0
fi

resolve_private_key() {
  local input_path="$1"
  local candidate

  if [[ -e "$input_path" ]]; then
    auto_realpath "$input_path"
    return
  fi

  candidate="$(pwd)/$input_path"
  if [[ -e "$candidate" ]]; then
    auto_realpath "$candidate"
    return
  fi

  candidate="$ENV_ROOT/$input_path"
  if [[ -e "$candidate" ]]; then
    auto_realpath "$candidate"
    return
  fi

  return 1
}

if ! CURRENT_KEY=$(resolve_private_key "$CURRENT_KEY"); then
  log_error "Current sealed secret private key not found at '$CURRENT_KEY'"
  exit 1
fi

CURRENT_KEY_DIR=$(dirname "$CURRENT_KEY")
ensure_directory "$CURRENT_KEY_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
NEW_KEY_BASENAME="${ENVIRONMENT}_${TIMESTAMP}_${NEW_ALGO}_Secret"
NEW_KEY_PATH="$CURRENT_KEY_DIR/${NEW_KEY_BASENAME}.key"
NEW_CERT_PATH="$CURRENT_KEY_DIR/${NEW_KEY_BASENAME}.crt"
NEW_TLS_SECRET_PATH="$CURRENT_KEY_DIR/${NEW_KEY_BASENAME}.yaml"

RSA_BITS=""
case "$NEW_ALGO" in
  RSA2048) RSA_BITS=2048 ;;
  RSA3072) RSA_BITS=3072 ;;
  RSA4096) RSA_BITS=4096 ;;
  *) ;;
esac

if [[ -n "$RSA_BITS" ]]; then
  log_info "Generating RSA${RSA_BITS} controller keypair"
  openssl req -x509 -nodes -newkey "rsa:${RSA_BITS}" -days 365 \
    -keyout "$NEW_KEY_PATH" -out "$NEW_CERT_PATH" -subj "/CN=sealed-secrets" >/dev/null 2>&1
else
  log_error "Unsupported algorithm '$NEW_ALGO'"
  exit 1
fi

NEW_KEY_PATH=$(auto_realpath "$NEW_KEY_PATH")
NEW_CERT_PATH=$(auto_realpath "$NEW_CERT_PATH")

CERT_B64=$(base64 -w0 "$NEW_CERT_PATH")
KEY_B64=$(base64 -w0 "$NEW_KEY_PATH")
TLS_SECRET_NAME="$NEW_KEY_BASENAME"

cat >"$NEW_TLS_SECRET_PATH" <<EOF
apiVersion: v1
kind: Secret
type: kubernetes.io/tls
metadata:
  name: $TLS_SECRET_NAME
  namespace: kube-system
data:
  tls.crt: $CERT_B64
  tls.key: $KEY_B64
EOF

log_info "TLS secret manifest written to $NEW_TLS_SECRET_PATH"

shopt -s nullglob

declare -a APP_NAMES BASE_PATHS OVERLAY_PATHS STAGE_SEALED_PATHS STAGE_UNSEALED_PATHS STAGE_RESEALED_PATHS UPDATE_MODES
ENTRY_COUNT=0

while IFS= read -r -d '' BASE_FILE; do
  ABS_BASE=$(auto_realpath "$BASE_FILE")
  RELATIVE_FROM_APPS=$(relative_path "$APPS_ROOT" "$ABS_BASE")

  STAGE_SEALED_PATH="$STAGE_SEALED/$RELATIVE_FROM_APPS"
  ensure_directory "$(dirname "$STAGE_SEALED_PATH")"
  cp "$BASE_FILE" "$STAGE_SEALED_PATH"

  APP_ROOT=$(dirname "$(dirname "$ABS_BASE")")
  APP_NAME=$(basename "$APP_ROOT")
  OVERLAY_PATH="$APP_ROOT/overlays/$ENVIRONMENT/$(basename "$BASE_FILE")"
  OVERLAY_ABS=""
  UPDATE_MODE="base"

  if [[ -f "$OVERLAY_PATH" ]]; then
    OVERLAY_ABS=$(auto_realpath "$OVERLAY_PATH")
    if [[ $(yq eval 'has("spec") and (.spec | has("encryptedData"))' "$OVERLAY_ABS") == "true" ]]; then
      yq eval --inplace '.spec.encryptedData = (load("'"$OVERLAY_ABS"'").spec.encryptedData)' "$STAGE_SEALED_PATH"
      UPDATE_MODE="overlay"
    else
      log_warn "Overlay '$OVERLAY_PATH' found but spec.encryptedData missing; using base data"
    fi
  fi

  STAGE_UNSEALED_PATH="$STAGE_UNSEALED/${RELATIVE_FROM_APPS/_SealedSecret/_Secret}"
  ensure_directory "$(dirname "$STAGE_UNSEALED_PATH")"

  STAGE_RESEALED_PATH="$STAGE_RESEALED/$RELATIVE_FROM_APPS"
  ensure_directory "$(dirname "$STAGE_RESEALED_PATH")"

  APP_NAMES[ENTRY_COUNT]="$APP_NAME"
  BASE_PATHS[ENTRY_COUNT]="$ABS_BASE"
  OVERLAY_PATHS[ENTRY_COUNT]="$OVERLAY_ABS"
  STAGE_SEALED_PATHS[ENTRY_COUNT]="$STAGE_SEALED_PATH"
  STAGE_UNSEALED_PATHS[ENTRY_COUNT]="$STAGE_UNSEALED_PATH"
  STAGE_RESEALED_PATHS[ENTRY_COUNT]="$STAGE_RESEALED_PATH"
  UPDATE_MODES[ENTRY_COUNT]="$UPDATE_MODE"

  ((ENTRY_COUNT++))
done < <(find "$APPS_ROOT" -type f -path '*/base/*_SealedSecret*.yaml' -print0)

if (( ENTRY_COUNT == 0 )); then
  log_error "No base SealedSecret files were found under '$APPS_ROOT'"
  exit 1
fi

for ((i=0; i<ENTRY_COUNT; i++)); do
  log_info "Unsealing ${APP_NAMES[i]} -> $(basename "${STAGE_SEALED_PATHS[i]}")"
  kubeseal --format=yaml --recovery-unseal --recovery-private-key "$CURRENT_KEY" \
    <"${STAGE_SEALED_PATHS[i]}" >"${STAGE_UNSEALED_PATHS[i]}"
done

for ((i=0; i<ENTRY_COUNT; i++)); do
  log_info "Resealing ${APP_NAMES[i]} -> $(basename "${STAGE_RESEALED_PATHS[i]}")"
  kubeseal --format=yaml --cert "$NEW_CERT_PATH" \
    <"${STAGE_UNSEALED_PATHS[i]}" >"${STAGE_RESEALED_PATHS[i]}"
done

for ((i=0; i<ENTRY_COUNT; i++)); do
  if [[ $(yq eval 'has("spec") and (.spec | has("encryptedData"))' "${STAGE_RESEALED_PATHS[i]}") != "true" ]]; then
    log_error "Resealed file '${STAGE_RESEALED_PATHS[i]}' lacks spec.encryptedData"
    exit 1
  fi

  if [[ "${UPDATE_MODES[i]}" == "overlay" && -n "${OVERLAY_PATHS[i]}" ]]; then
    yq eval --inplace '.spec.encryptedData = (load("'"${STAGE_RESEALED_PATHS[i]}"'").spec.encryptedData)' "${OVERLAY_PATHS[i]}"
    log_info "Updated overlay encryptedData for ${APP_NAMES[i]} [$ENVIRONMENT]"
  else
    cp "${STAGE_RESEALED_PATHS[i]}" "${BASE_PATHS[i]}"
    log_info "Updated base sealed secret for ${APP_NAMES[i]}"
  fi
done

printf '\nRotation complete.\n'
printf 'New key:  %s\n' "$NEW_KEY_PATH"
printf 'New cert: %s\n' "$NEW_CERT_PATH"
printf 'New TLS Secret manifest: %s\n' "$NEW_TLS_SECRET_PATH"
