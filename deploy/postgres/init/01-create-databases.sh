#!/usr/bin/env bash
# Runs once, on an empty data directory. Creates the app and Keycloak databases
# with their own least-privilege owners.
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v app_db="$APP_DB" -v app_user="$APP_DB_USER" -v app_pw="$APP_DB_PASSWORD" \
  -v kc_db="$KEYCLOAK_DB" -v kc_user="$KEYCLOAK_DB_USER" -v kc_pw="$KEYCLOAK_DB_PASSWORD" <<'SQL'
CREATE ROLE :"app_user" LOGIN PASSWORD :'app_pw';
CREATE DATABASE :"app_db" OWNER :"app_user";
REVOKE ALL ON DATABASE :"app_db" FROM PUBLIC;

CREATE ROLE :"kc_user" LOGIN PASSWORD :'kc_pw';
CREATE DATABASE :"kc_db" OWNER :"kc_user";
REVOKE ALL ON DATABASE :"kc_db" FROM PUBLIC;
SQL
