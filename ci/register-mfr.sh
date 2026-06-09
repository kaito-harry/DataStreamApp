#!/bin/bash
# Register the actrium manufacturer key in actrix's MFR database
# This allows the AIS to verify packages signed with the dev key

DB="/tmp/actrix-ci/db/actrix.db"
PUBKEY=$(cat ci/dev-pubkey.json | python3 -c "import json,sys; print(json.load(sys.stdin)['public_key'])")
KEY_ID="mfr-3c26d99da4503044"
NOW=$(date +%s)

sqlite3 "$DB" << SQL
INSERT OR IGNORE INTO mfr (name, public_key, key_id, status, created_at, verified_at)
VALUES ('actrium', '$PUBKEY', '$KEY_ID', 'active', $NOW, $NOW);
SQL

echo "MFR registration:"
sqlite3 "$DB" "SELECT id, name, key_id, status FROM mfr WHERE name='actrium';"
