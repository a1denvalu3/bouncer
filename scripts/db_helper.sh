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
    # Note: Use -batch to avoid interactive prompts
    sqlcipher -batch -cmd "PRAGMA key = '${PASSPHRASE}';" "$DB_PATH" "$query"
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
