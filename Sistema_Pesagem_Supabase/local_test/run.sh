#!/bin/bash
# Recria o banco local e aplica stub + migrations + seed + testes
set -e
P="psql -h /tmp -p 5433 -U postgres -v ON_ERROR_STOP=1 -q"
D=$(cd "$(dirname "$0")/.." && pwd)
$P -d postgres -c "drop database if exists pesagem_test" -c "create database pesagem_test"
$P -d pesagem_test -f "$D/local_test/00_supabase_stub.sql"
for f in "$D"/supabase/migrations/*.sql; do echo "== $(basename $f)"; $P -d pesagem_test -f "$f"; done
echo "== seed"; $P -d pesagem_test -f "$D/supabase/seed_exemplo.sql"
echo "== testes"; $P -d pesagem_test -f "$D/supabase/tests/pesagem_tests.sql"
echo "== concorrencia"; PSQL="psql -h /tmp -p 5433 -U postgres -d pesagem_test" "$D/supabase/tests/concorrencia_test.sh"
