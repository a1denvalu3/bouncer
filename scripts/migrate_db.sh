#!/bin/bash

# migrate_db.sh
# Handles SQL schema creation and zero-data-loss migrations from old JSON/file state

source /app/scripts/db_helper.sh

echo "Initializing SQLCipher database at /out/bouncer.db..."

# 1. Create Base Tables
execute_sql "
CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    migrated_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS pr_reviews (
    repo TEXT,
    pr_number INTEGER,
    head_oid TEXT,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (repo, pr_number)
);
CREATE TABLE IF NOT EXISTS pr_reports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    repo TEXT,
    pr_number INTEGER,
    head_oid TEXT,
    report_text TEXT,
    metrics_json TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
"

# 2. Get current migration version
VERSION=$(execute_sql "SELECT COALESCE(MAX(version), 0) FROM schema_migrations;")

# 3. Apply Migrations
if [ "$VERSION" -eq 0 ]; then
    echo "Running migration 0 -> 1 (Migrating state.json to SQLCipher)..."
    
    # Safely migrate existing JSON state
    if [ -f "/out/state.json" ]; then
        echo "Found state.json. Migrating tracking data to pr_reviews table..."
        
        jq -r 'to_entries | .[] | "\(.key) \(.value)"' /out/state.json | while read -r line; do
            # Format: org/repo_pr hash
            # Need to carefully split by the LAST underscore since repos can have underscores
            key=$(echo "$line" | awk '{print $1}')
            val=$(echo "$line" | awk '{print $2}')
            
            repo="${key%_*}"
            pr="${key##*_}"
            
            # Simple sanitization
            repo=$(echo "$repo" | tr -d "'")
            val=$(echo "$val" | tr -d "'")
            
            execute_sql "INSERT OR REPLACE INTO pr_reviews(repo, pr_number, head_oid) VALUES('${repo}', ${pr}, '${val}');"
        done
        
        # Backup the old state file (do not delete for safety)
        mv /out/state.json /out/state.json.bak
        echo "state.json migrated and backed up to state.json.bak"
    fi
    
    # We do not forcefully migrate old flat-file reports into the DB here because:
    # 1. Filename mapping back to exact OID is ambiguous in the old folder structure.
    # 2. Old reports are already secure in the volume. 
    # New reports will be ingested cleanly.
    
    execute_sql "INSERT INTO schema_migrations(version) VALUES(1);"
    echo "Migration 0 -> 1 complete."
fi

echo "Database initialization complete."
