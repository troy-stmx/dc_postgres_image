#!/usr/bin/env bash
# =============================================================================
# PostgreSQL runtime container entrypoint
# =============================================================================
# Responsibilities:
#   1. Initialize PostgreSQL data directory.
#   2. Generate PostgreSQL configuration from environment variables.
#   3. Create the application user and database.
#   4. Install the VectorChord extension (which installs pgvector via CASCADE)
#      and the zhparser Chinese full-text search extension.
#   5. Optionally run a post-setup command for one-off maintenance tasks.
#   6. Optionally start SSH for development/debugging.
#   7. Keep PostgreSQL running in the foreground lifecycle.
#
# Schema migration belongs in a separate application/migration container.
# =============================================================================

set -euo pipefail

show_help() {
  cat <<'EOF'
PostgreSQL runtime container entrypoint

Usage:
  docker run --rm -e POSTGRES_PASSWORD=xxx ghcr.io/<owner>/dc_postgres_image:<tag>
  docker run --rm ghcr.io/<owner>/dc_postgres_image:<tag> --help

Environment variables:
  POSTGRES_PASSWORD    Application user password              (default: dc_admin_pass)
  POSTGRES_USER        Application user name                  (default: dc_admin)
  POSTGRES_DB          Application database name              (default: dc_db)
  POSTGRES_DB_PORT     PostgreSQL port                        (default: 5432)
  POSTGRES_ROOT        PostgreSQL data directory              (default: /pgdata)
  POST_SETUP_CMD       Optional command after DB setup        (default: empty)
  SKIP_PG              Skip PostgreSQL startup when set to 1  (default: 0)
  SKIP_SSH             Skip SSH startup when set to 1         (default: 1)

Configuration variables are handled by /opt/dc-postgres/docker/postgres_config.sh.
EOF
  exit 0
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  show_help
fi

PG_ROOT="${POSTGRES_ROOT:-/pgdata}"
PG_USER="${POSTGRES_USER:-dc_admin}"
PG_DB="${POSTGRES_DB:-dc_db}"
PG_PASSWORD="${POSTGRES_PASSWORD:-dc_admin_pass}"
PG_PORT="${POSTGRES_DB_PORT:-5432}"
export PG_DB_PORT="${PG_PORT}"

PG_SYS_USER="postgres"
PG_BIN="/usr/local/pgsql/bin"
PG_HOST="localhost"
SCRIPT_ROOT="/opt/dc-postgres"

SKIP_PG="${SKIP_PG:-0}"
SKIP_SSH="${SKIP_SSH:-1}"
POST_SETUP_CMD="${POST_SETUP_CMD:-}"

mkdir -p /home/postgres
chown postgres:postgres /home/postgres

log() { printf '[entrypoint] %s\n' "$*"; }
ok() { log "✓ $*"; }
err() { log "✗ $*" >&2; }

init_postgres() {
  if [[ -f "${PG_ROOT}/PG_VERSION" ]]; then
    ok "Data directory already exists, skipping initdb: ${PG_ROOT}"
    return 0
  fi

  log "Initializing PostgreSQL data directory: ${PG_ROOT}"
  mkdir -p "${PG_ROOT}"
  chown "${PG_SYS_USER}:${PG_SYS_USER}" "${PG_ROOT}"

  su - "${PG_SYS_USER}" -c "${PG_BIN}/initdb -D ${PG_ROOT} --encoding=UTF8 --locale=C.UTF-8 --auth=trust"
  ok "initdb completed"

  log "Generating PostgreSQL configuration"
  bash "${SCRIPT_ROOT}/docker/postgres_config.sh" "${PG_ROOT}" "${PG_SYS_USER}"

  # In-container bootstrap uses trust auth, matching the previous dc_db image behavior.
  sed -i 's/scram-sha-256/trust/g' "${PG_ROOT}/pg_hba.conf"
  chown "${PG_SYS_USER}:${PG_SYS_USER}" "${PG_ROOT}/pg_hba.conf"
  ok "Configuration files generated"
}

start_postgres() {
  log "Starting PostgreSQL..."
  mkdir -p "${PG_ROOT}/log"
  chown "${PG_SYS_USER}:${PG_SYS_USER}" "${PG_ROOT}/log"

  su - "${PG_SYS_USER}" -c "${PG_BIN}/pg_ctl start -D ${PG_ROOT} -l ${PG_ROOT}/log/postgresql-startup.log -w"
  ok "PostgreSQL started"

  local retries=30
  while (( retries > 0 )); do
    if su - "${PG_SYS_USER}" -c "${PG_BIN}/pg_isready -h ${PG_HOST} -p ${PG_PORT}" &>/dev/null; then
      ok "PostgreSQL is ready"
      return 0
    fi
    retries=$((retries - 1))
    sleep 0.5
  done

  err "PostgreSQL startup timed out"
  return 1
}

setup_database() {
  local user_exists
  user_exists=$(su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -tAc \"SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'\"")

  if [[ "${user_exists}" == "1" ]]; then
    ok "User ${PG_USER} already exists"
  else
    log "Creating user: ${PG_USER}"
    su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -c \"CREATE USER ${PG_USER} WITH SUPERUSER PASSWORD '${PG_PASSWORD}'\""
    ok "User ${PG_USER} created"
  fi

  local db_exists
  db_exists=$(su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -lqt" | cut -d \| -f 1 | grep -qw "${PG_DB}" && echo "1" || echo "0")

  if [[ "${db_exists}" == "1" ]]; then
    ok "Database ${PG_DB} already exists"
  else
    log "Creating database: ${PG_DB}"
    su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -c \"CREATE DATABASE ${PG_DB} OWNER ${PG_USER}\""
    ok "Database ${PG_DB} created"
  fi

  log "Installing extension: vchord CASCADE"
  su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -d ${PG_DB} -c 'CREATE EXTENSION IF NOT EXISTS vchord CASCADE'"
  ok "Extensions installed"

  log "Installing extension: zhparser (Chinese text search)"
  su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -d ${PG_DB} -c 'CREATE EXTENSION IF NOT EXISTS zhparser'"
  su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -d ${PG_DB} -c 'DO \$do\$ BEGIN CREATE TEXT SEARCH CONFIGURATION chinese_zh (PARSER = zhparser); EXCEPTION WHEN others THEN NULL; END \$do\$'"
  su - "${PG_SYS_USER}" -c "${PG_BIN}/psql -h ${PG_HOST} -p ${PG_PORT} -d ${PG_DB} -c \"ALTER TEXT SEARCH CONFIGURATION chinese_zh ADD MAPPING FOR n,v,a,i,e,l WITH simple\""
  ok "zhparser and Chinese text search configuration installed"
}

run_post_setup_cmd() {
  if [[ -z "${POST_SETUP_CMD}" ]]; then
    return 0
  fi

  log "Running POST_SETUP_CMD: ${POST_SETUP_CMD}"
  eval "${POST_SETUP_CMD}"
  ok "POST_SETUP_CMD completed"

  log "One-shot mode: stopping PostgreSQL and exiting"
  su - "${PG_SYS_USER}" -c "${PG_BIN}/pg_ctl stop -D ${PG_ROOT} -m fast" 2>/dev/null || true
  exit 0
}

start_ssh() {
  if [[ "${SKIP_SSH}" == "1" ]]; then
    return 0
  fi

  log "Starting SSH service..."
  echo "root:root" | chpasswd
  /usr/sbin/sshd
  ok "SSH started on port 22"
}

run_foreground() {
  if [[ "${SKIP_PG}" == "1" ]]; then
    log "SKIP_PG=1, keeping container alive with sleep infinity"
    exec sleep infinity
  fi

  log "Container is ready; PostgreSQL is running"
  log "  Connection: postgresql://${PG_USER}:***@${PG_HOST}:${PG_PORT}/${PG_DB}"
  log "  Data directory: ${PG_ROOT}"

  su - "${PG_SYS_USER}" -c "tail -f ${PG_ROOT}/log/postgresql-*.log 2>/dev/null || sleep infinity" &
  wait $! 2>/dev/null
}

cleanup() {
  log "Received stop signal, shutting down PostgreSQL..."
  kill $(jobs -p) 2>/dev/null || true
  su - "${PG_SYS_USER}" -c "${PG_BIN}/pg_ctl stop -D ${PG_ROOT} -m fast" 2>/dev/null || true
}

trap cleanup SIGTERM SIGINT SIGQUIT

log "========== dc-postgres runtime container starting =========="

if [[ "${SKIP_PG}" != "1" ]]; then
  init_postgres
  start_postgres
  setup_database
fi

run_post_setup_cmd
start_ssh

touch /tmp/pg_ready
log "========== startup completed =========="
run_foreground
