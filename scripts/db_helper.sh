#!/bin/bash

# db_helper.sh
# Utility functions to interact with the encrypted SQLCipher database

DB_PATH="/out/bouncer.db"

if [ -z "$DB_PASSPHRASE" ]; then
    echo "ERROR: DB_PASSPHRASE environment variable is not set. An encryption key is required for SQLCipher."
    exit 1
fi

PASSPHRASE="$DB_PASSPHRASE"

verify_db_passphrase() {
    # If the database file exists and is not empty, verify the passphrase is correct
    if [ -s "$DB_PATH" ]; then
        if ! sqlcipher -batch -cmd "PRAGMA key = '${PASSPHRASE}';" "$DB_PATH" "SELECT count(*) FROM sqlite_master;" >/dev/null 2>&1; then
            echo "ERROR: DB_PASSPHRASE is incorrect or the database at $DB_PATH is corrupted. Failed to decrypt."
            exit 1
        fi
    fi
}

# Verify passphrase on script load
verify_db_passphrase

execute_sql() {
    local query="$1"
    # Note: Use -batch to avoid interactive prompts.
    # SQLCipher 4.x prints "ok" for the PRAGMA key command; strip that first line so
    # scalar query results (versions, OIDs, ledger text) stay clean.
    sqlcipher -batch -cmd "PRAGMA key = '${PASSPHRASE}';" "$DB_PATH" "$query" | sed '1{/^ok$/d}'
}

# Helper to safely insert a file's contents into a BLOB column (which we can then cast to TEXT)
# We convert the file to a hex string to completely bypass any SQL injection risks with multiline/quotes
execute_sql_insert_file() {
    local repo="$1"
    local pr="$2"
    local oid="$3"
    local report_file="$4"
    local metrics_file="$5"
    
    local report_hex=""
    local metrics_hex=""

    # Convert files to hex safely if they exist
    if [ -f "$report_file" ]; then
        report_hex=$(od -A n -v -t x1 < "$report_file" | tr -d ' \n')
    fi
    
    if [ -f "$metrics_file" ]; then
        metrics_hex=$(od -A n -v -t x1 < "$metrics_file" | tr -d ' \n')
    fi

    # Using CAST(X'hex' AS TEXT) allows us to safely ingest arbitrary text data
    local sql="INSERT INTO pr_reports (repo, pr_number, head_oid, report_text, metrics_json) VALUES ("
    sql+="'${repo}', ${pr}, '${oid}', "
    
    if [ -n "$report_hex" ]; then
        sql+="CAST(X'${report_hex}' AS TEXT), "
    else
        sql+="NULL, "
    fi
    
    if [ -n "$metrics_hex" ]; then
        sql+="CAST(X'${metrics_hex}' AS TEXT)"
    else
        sql+="NULL"
    fi
    
    sql+=");"
    
    execute_sql "$sql"
}

# Returns 0 when the report file declares an actual finding.
# Reports whose YAML frontmatter sets `finding: false` are clean-PR
# write-ups (no vulnerability identified) and must NOT be ingested.
# A missing field is treated as a finding for backwards compatibility
# with reports written before the field existed.
report_has_finding() {
    local report_file="$1"
    # Inspect only the frontmatter block (between the first two --- lines)
    if awk '/^---[[:space:]]*$/{c++; next} c==1' "$report_file" | \
        grep -qiE '^finding:[[:space:]]*["'"'"']?false["'"'"']?[[:space:]]*$'; then
        return 1
    fi
    return 0
}

# Mark all unresolved reports for a given PR as resolved by a later PR.
# The reason text uses the same hex/CAST pattern as report ingestion so
# arbitrary agent-written text cannot break the SQL.
mark_report_resolved() {
    local repo="$1"
    local orig_pr="$2"
    local resolved_by="$3"
    local reason="$4"

    local reason_hex=""
    if [ -n "$reason" ]; then
        reason_hex=$(printf '%s' "$reason" | od -A n -v -t x1 | tr -d ' \n')
    fi

    local sql="UPDATE pr_reports SET resolved_by_pr=${resolved_by}, resolved_at=CURRENT_TIMESTAMP"
    if [ -n "$reason_hex" ]; then
        sql+=", resolved_reason=CAST(X'${reason_hex}' AS TEXT)"
    fi
    sql+=" WHERE repo='${repo}' AND pr_number=${orig_pr} AND resolved_by_pr IS NULL;"

    execute_sql "$sql"
}

# Retrieve the carry-forward findings ledger for a repo (empty if none exists yet)
get_ledger() {
    local repo="$1"
    execute_sql "SELECT ledger_text FROM backfill_ledger WHERE repo='${repo}';"
}

# Safely store the findings ledger for a repo using the same hex/CAST pattern as reports
put_ledger() {
    local repo="$1"
    local ledger_file="$2"
    
    local ledger_hex=""
    if [ -f "$ledger_file" ]; then
        ledger_hex=$(od -A n -v -t x1 < "$ledger_file" | tr -d ' \n')
    fi

    local sql="INSERT OR REPLACE INTO backfill_ledger (repo, ledger_text, updated_at) VALUES ('${repo}', "
    if [ -n "$ledger_hex" ]; then
        sql+="CAST(X'${ledger_hex}' AS TEXT), CURRENT_TIMESTAMP);"
    else
        sql+="'', CURRENT_TIMESTAMP);"
    fi

    execute_sql "$sql"
}
