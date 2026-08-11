#!/usr/bin/env bash
# purge_yourmetrics.sh
# Loops through all databases in a Postgres cluster. For each database with a
# sboms table, runs two passes over the same set of rows (rows older than
# RETENTION, excluding protected/release branches):
#   1. Export the rows to CSV and upload to S3
#   2. Delete the rows from the table
# Also writes Prometheus node-exporter textfile metrics.
#
# Cron example (weekly, Sunday 02:00):
#   0 2 * * 0 /opt/scripts/purge_yourmetrics.sh >> /var/log/purge_yourmetrics.log 2>&1

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration – override via environment or edit defaults below
# ---------------------------------------------------------------------------
RETENTION="${RETENTION:-90 days}"
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
# PGPASSWORD can be set in the environment or use a ~/.pgpass file
PGPASSWORD="${PGPASSWORD:-}"
export PGPASSWORD

# S3 destination for the pre-delete CSV export. Requires the aws CLI to be
# installed and configured (IAM role, profile, or credentials in env).
S3_BUCKET="${S3_BUCKET:?S3_BUCKET must be set}"
S3_PREFIX="${S3_PREFIX:-yourmetrics-purge}"
# Optional: shell env file with `export AWS_ACCESS_KEY_ID=...` etc, sourced
# before the credentials check below. Leave unset to rely on an instance/task
# IAM role, ~/.aws/credentials, or credentials already in the environment.
AWS_CREDENTIALS_FILE="${AWS_CREDENTIALS_FILE:-}"

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
log "Starting yourmetric purge (retention=${RETENTION})"

command -v aws >/dev/null 2>&1 || { err "aws CLI not found in PATH"; exit 1; }

if [[ -n "$AWS_CREDENTIALS_FILE" ]]; then
    [[ -r "$AWS_CREDENTIALS_FILE" ]] || { err "AWS_CREDENTIALS_FILE set but not readable: $AWS_CREDENTIALS_FILE"; exit 1; }
    log "Sourcing AWS credentials from $AWS_CREDENTIALS_FILE"
    set -a
    # shellcheck disable=SC1090
    source "$AWS_CREDENTIALS_FILE"
    set +a
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
    err "AWS credentials are not valid or not configured (aws sts get-caller-identity failed)"
    exit 1
fi

if ! aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
    err "Cannot access S3 bucket '$S3_BUCKET' with current credentials"
    exit 1
fi

mapfile -t ALL_DBS < <(
    psql_cmd -d postgres -c \
        "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname;"
)

# Pin the retention cutoff to a single point in time (per Postgres's clock) so
# the export pass and the delete pass operate on exactly the same row set.
# Using NOW() separately in each query would let the delete pass catch rows
# that were never exported to S3.
CUTOFF=$(
    psql_cmd -d postgres -c \
        "SELECT (NOW() - INTERVAL '${RETENTION}')::timestamptz;"
)

# Never purge rows on protected branches, their remotes, or anything under
# release%, regardless of age.
PROTECTED_BRANCHES_ARRAY="ARRAY['master','main','dev','develop','uat','prod',
    'remotes/origin/master','remotes/origin/main','remotes/origin/dev','remotes/origin/develop',
    'remotes/origin/uat','remotes/origin/prod',
    'remotes/master','remotes/main','remotes/dev','remotes/develop','remotes/uat','remotes/prod']"

WHERE_CLAUSE="posted_at < '${CUTOFF}'
    AND NOT (
        git_branches && ${PROTECTED_BRANCHES_ARRAY}
        OR EXISTS (
            SELECT 1 FROM UNNEST(git_branches) AS branch
            WHERE branch LIKE 'release%'
               OR branch LIKE 'remotes/origin/release%'
               OR branch LIKE 'remotes/release%'
        )
    )"
log "Retention cutoff: ${CUTOFF}"

# ---------------------------------------------------------------------------
# Counters for aggregate metrics
# ---------------------------------------------------------------------------
total_rows_deleted=0
total_rows_exported=0
total_dbs_processed=0
total_dbs_skipped=0
total_dbs_error=0
job_start_epoch=$(date +%s)
run_date=$(date -u '+%Y%m%d_%H%M%S')

# ---------------------------------------------------------------------------
# Per-database work
# ---------------------------------------------------------------------------
declare -A db_rows_deleted   # associative array for per-db metrics
declare -A db_rows_exported

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

    # Check if the sboms table exists in this database
    table_exists=$(
        psql_cmd -d "$db" -c \
            "SELECT COUNT(*) FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'sboms';"
    )

    if [[ "$table_exists" -eq 0 ]]; then
        log "  Table 'sboms' not found in $db – skipping"
        (( total_dbs_skipped++ )) || true
        db_rows_deleted["$db"]=0
        db_rows_exported["$db"]=0
        continue
    fi

    # -----------------------------------------------------------------------
    # Pass 1: export matching rows to CSV and upload to S3
    # -----------------------------------------------------------------------
    s3_key="${S3_PREFIX}/${db}/sboms_${run_date}.csv.gz"
    s3_uri="s3://${S3_BUCKET}/${s3_key}"

    exported=$(
        psql_cmd -d "$db" -c \
            "SELECT COUNT(*) FROM sboms WHERE ${WHERE_CLAUSE};"
    )

    if [[ "$exported" -eq 0 ]]; then
        log "  No rows to export from $db"
        db_rows_exported["$db"]=0
    else
        if ! psql_cmd -d "$db" -c \
                "COPY (SELECT * FROM sboms WHERE ${WHERE_CLAUSE}) TO STDOUT WITH CSV HEADER" \
            | gzip \
            | aws s3 cp - "$s3_uri" --content-type "text/csv" --content-encoding "gzip"; then
            err "  CSV export to $s3_uri failed for $db"
            (( total_dbs_error++ )) || true
            db_rows_exported["$db"]=-1   # sentinel: error
            db_rows_deleted["$db"]=-1
            continue
        fi
        log "  Exported ${exported} rows from $db to ${s3_uri}"
        db_rows_exported["$db"]=$exported
        (( total_rows_exported += exported )) || true
    fi

    # -----------------------------------------------------------------------
    # Pass 2: delete the same rows from the table
    # -----------------------------------------------------------------------
    deleted=$(
        psql_cmd -d "$db" -c \
            "WITH deleted AS (
                 DELETE FROM sboms
                 WHERE ${WHERE_CLAUSE}
                 RETURNING 1
             )
             SELECT COUNT(*) FROM deleted;"
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

log "Finished. total_exported=${total_rows_exported} total_deleted=${total_rows_deleted}" \
    "dbs_processed=${total_dbs_processed} dbs_skipped=${total_dbs_skipped}" \
    "dbs_error=${total_dbs_error} duration=${job_duration}s"

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

# HELP yourmetric_purge_retention_info Configured retention period (value is always 1; retention is exposed as a label).
# TYPE yourmetric_purge_retention_info gauge
yourmetric_purge_retention_info{retention="${RETENTION}"} 1

# HELP yourmetric_purge_rows_exported_total Total rows exported to S3 across all databases in the last run.
# TYPE yourmetric_purge_rows_exported_total gauge
yourmetric_purge_rows_exported_total ${total_rows_exported}

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

# HELP yourmetric_purge_rows_exported_per_db Rows exported to S3 per database in the last run (-1 indicates an error).
# TYPE yourmetric_purge_rows_exported_per_db gauge
EOF
    for db in "${!db_rows_exported[@]}"; do
        echo "yourmetric_purge_rows_exported_per_db{database=\"${db}\"} ${db_rows_exported[$db]}"
    done

    cat <<EOF

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
