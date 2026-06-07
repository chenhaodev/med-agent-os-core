#!/usr/bin/env bash
# Apply schema.sql to the OS database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# shellcheck source=../lib/common.sh
source "$BASE_DIR/lib/common.sh"

DB_FILE="${OS_DB:-$BASE_DIR/var/os.db}"

mkdir -p "$(dirname "$DB_FILE")"

log_info "Applying schema to $DB_FILE"
sqlite3 "$DB_FILE" < "$SCRIPT_DIR/schema.sql"
log_info "Migration complete"
