#!/usr/bin/env bash
# purge_yourmetrics.sh
# Loops through all databases in a Postgres cluster, deletes yourmetric rows older
# than RETENTION_DAYS, and writes Prometheus node-exporter textfile metrics.
#
# Cron example (weekly, Sunday 02:00):
#   0 2 * * 0 /opt/scripts/purge_yourmetrics.sh >> /var/log/purge_yourmetrics.log 2>&1

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration – override via environment or edit defaults below
# ---------------------------------------------------------------------------
RETENTION_DAYS="${RETENTION_DAYS:-90}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
# PGPASSWORD can be set in the environment or use a ~/.pgpass file
PGPASSWORD="${PGPASSWORD:-}"
export PGPASSWORD

# Prometheus textfile collector directory (must be readable by node_exporter)
METRICS_DIR="${METRICS_DIR:-/var/lib/node_exporter/textfile_collector}"
METRICS_FILE="${METRICS_DIR}/yourmetric_purge.prom"
METRICS_TMP="${METRICS_FILE}.$$"   # write to a temp file then atomic-rename

# Databases to skip (space-separated)
SKIP_DBS="template0 template1 postgres"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [INFO]  $*"; }
warn() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [WARN]  $*" >&2; }
err()  { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [ERROR] $*" >&2; }

psql_cmd() {
    psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -v ON_ERROR_STOP=1 \
         --no-align --tuples-only --quiet "$@"
}

# ---------------------------------------------------------------------------
# Gather list of databases
# ---------------------------------------------------------------------------
log "Starting yourmetric purge (retention=${RETENTION_DAYS} days)"

mapfile -t ALL_DBS < <(
    psql_cmd -d postgres -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
)

# ---------------------------------------------------------------------------
# Counters for aggregate metrics
# ---------------------------------------------------------------------------
total_rows_deleted=0
total_dbs_processed=0
total_dbs_skipped=0
total_dbs_error=0
job_start_epoch=$(date +%s)

# ---------------------------------------------------------------------------
# Per-database work
# ---------------------------------------------------------------------------
declare -A db_rows_deleted   # associative array for per-db metrics

for db in "${ALL_DBS[@]}"; do
    # Trim whitespace that psql may leave
    db="${db// /}"
    [[ -z "$db" ]] && continue

    # Skip system databases
    if echo "$SKIP_DBS" | grep -qw "$db"; then
        log "Skipping system database: $db"
        (( total_dbs_skipped++ )) || true
        continue
    fi

    log "Processing database: $db"

    # Check if the yourmetrics table exists in this database
    table_exists=$(
        psql_cmd -d "$db" -c \
            "SELECT COUNT(*) FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'yourmetrics';"
    )

    if [[ "$table_exists" -eq 0 ]]; then
        log "  Table 'yourmetrics' not found in $db – skipping"
        (( total_dbs_skipped++ )) || true
        db_rows_deleted["$db"]=0
        continue
    fi

    # Run the delete and capture the row count
    # Assumes the yourmetrics table has a column called 'created_at' (TIMESTAMPTZ/DATE).
    # Adjust the column name below if yours differs.
    deleted=$(
        psql_cmd -d "$db" -c \
            "DELETE FROM yourmetrics
             WHERE created_at < NOW() - INTERVAL '${RETENTION_DAYS} days'
             RETURNING 1;" \
        | wc -l | tr -d ' '
    ) || {
        err "  Delete failed on $db"
        (( total_dbs_error++ )) || true
        db_rows_deleted["$db"]=-1   # sentinel: error
        continue
    }

    log "  Deleted ${deleted} rows from $db"
    db_rows_deleted["$db"]=$deleted
    (( total_rows_deleted += deleted )) || true
    (( total_dbs_processed++ )) || true
done

job_end_epoch=$(date +%s)
job_duration=$(( job_end_epoch - job_start_epoch ))
job_success=1   # if we reach here the overall job didn't crash

log "Finished. total_deleted=${total_rows_deleted} dbs_processed=${total_dbs_processed}" \
    "dbs_skipped=${total_dbs_skipped} dbs_error=${total_dbs_error}" \
    "duration=${job_duration}s"

# ---------------------------------------------------------------------------
# Write Prometheus metrics to a temp file then atomically rename
# ---------------------------------------------------------------------------
mkdir -p "$METRICS_DIR"

{
    # ---- Job-level metrics ------------------------------------------------
    cat <<EOF
# HELP yourmetric_purge_last_run_timestamp_seconds Unix timestamp of the last purge job run.
# TYPE yourmetric_purge_last_run_timestamp_seconds gauge
yourmetric_purge_last_run_timestamp_seconds ${job_end_epoch}

# HELP yourmetric_purge_duration_seconds Wall-clock time the purge job took to complete.
# TYPE yourmetric_purge_duration_seconds gauge
yourmetric_purge_duration_seconds ${job_duration}

# HELP yourmetric_purge_success Whether the last purge job completed without a fatal error (1=success, 0=failure).
# TYPE yourmetric_purge_success gauge
yourmetric_purge_success ${job_success}

# HELP yourmetric_purge_retention_days Configured retention period in days.
# TYPE yourmetric_purge_retention_days gauge
yourmetric_purge_retention_days ${RETENTION_DAYS}

# HELP yourmetric_purge_rows_deleted_total Total rows deleted across all databases in the last run.
# TYPE yourmetric_purge_rows_deleted_total gauge
yourmetric_purge_rows_deleted_total ${total_rows_deleted}

# HELP yourmetric_purge_databases_processed_total Number of databases where a delete was attempted.
# TYPE yourmetric_purge_databases_processed_total gauge
yourmetric_purge_databases_processed_total ${total_dbs_processed}

# HELP yourmetric_purge_databases_skipped_total Number of databases skipped (no table or system db).
# TYPE yourmetric_purge_databases_skipped_total gauge
yourmetric_purge_databases_skipped_total ${total_dbs_skipped}

# HELP yourmetric_purge_databases_error_total Number of databases where the delete returned an error.
# TYPE yourmetric_purge_databases_error_total gauge
yourmetric_purge_databases_error_total ${total_dbs_error}

# HELP yourmetric_purge_rows_deleted_per_db Rows deleted per database in the last run (-1 indicates an error).
# TYPE yourmetric_purge_rows_deleted_per_db gauge
EOF

    # ---- Per-database labelled metrics ------------------------------------
    for db in "${!db_rows_deleted[@]}"; do
        echo "yourmetric_purge_rows_deleted_per_db{database=\"${db}\"} ${db_rows_deleted[$db]}"
    done

} > "$METRICS_TMP"

mv "$METRICS_TMP" "$METRICS_FILE"
log "Prometheus metrics written to ${METRICS_FILE}"
