#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# PostgreSQL configuration generator
# -----------------------------------------------------------------------------
# Generates optimized postgresql.conf and pg_hba.conf files.
# Key parameters can be customized through environment variables.
#
# Optional environment variables:
#   PG_SHARED_BUFFERS        - Shared buffer size (default: 256MB)
#   PG_EFFECTIVE_CACHE_SIZE  - Effective cache size (default: 1GB)
#   PG_WORK_MEM              - Per-operation working memory (default: 16MB)
#   PG_MAINTENANCE_WORK_MEM  - Maintenance operation memory (default: 128MB)
#   PG_DB_PORT               - Listening port (default: 5432)
#   PG_MAX_CONNECTIONS       - Maximum connection count (default: 200)
#   PG_SYNCHRONOUS_COMMIT    - Synchronous commit mode (default: off)
#   PG_MAX_WAL_SIZE          - Maximum WAL size (default: 2GB)
#   PG_MIN_WAL_SIZE          - Minimum WAL size (default: 512MB)
#   PG_LOG_MIN_DURATION      - Slow query threshold in milliseconds (default: 1000)
# -----------------------------------------------------------------------------

set -euo pipefail

# =============================================================================
# Configuration parameters, overridable via environment variables
# =============================================================================

# Memory settings
PG_SHARED_BUFFERS="${PG_SHARED_BUFFERS:-256MB}"
PG_EFFECTIVE_CACHE_SIZE="${PG_EFFECTIVE_CACHE_SIZE:-1GB}"
PG_WORK_MEM="${PG_WORK_MEM:-16MB}"
PG_MAINTENANCE_WORK_MEM="${PG_MAINTENANCE_WORK_MEM:-128MB}"

# Connection settings
PG_DB_PORT="${PG_DB_PORT:-5432}"
PG_MAX_CONNECTIONS="${PG_MAX_CONNECTIONS:-200}"

# WAL and checkpoint settings
PG_WAL_BUFFERS="${PG_WAL_BUFFERS:-16MB}"
PG_MAX_WAL_SIZE="${PG_MAX_WAL_SIZE:-2GB}"
PG_MIN_WAL_SIZE="${PG_MIN_WAL_SIZE:-512MB}"
PG_CHECKPOINT_TIMEOUT="${PG_CHECKPOINT_TIMEOUT:-15min}"
PG_CHECKPOINT_COMPLETION_TARGET="${PG_CHECKPOINT_COMPLETION_TARGET:-0.9}"

# Asynchronous write setting.
# off: improves write throughput but can lose the latest 0-600ms of data on crash.
# on: ensures every commit is flushed durably at a higher performance cost.
PG_SYNCHRONOUS_COMMIT="${PG_SYNCHRONOUS_COMMIT:-off}"

# Query planner settings.
# SSD recommendation: random_page_cost=1.1, effective_io_concurrency=200.
# HDD default: random_page_cost=4.0, effective_io_concurrency=2.
PG_RANDOM_PAGE_COST="${PG_RANDOM_PAGE_COST:-4.0}"
PG_EFFECTIVE_IO_CONCURRENCY="${PG_EFFECTIVE_IO_CONCURRENCY:-2}"
PG_DEFAULT_STATISTICS_TARGET="${PG_DEFAULT_STATISTICS_TARGET:-100}"

# Parallel query settings
PG_MAX_WORKER_PROCESSES="${PG_MAX_WORKER_PROCESSES:-8}"
PG_MAX_PARALLEL_WORKERS="${PG_MAX_PARALLEL_WORKERS:-4}"
PG_MAX_PARALLEL_WORKERS_PER_GATHER="${PG_MAX_PARALLEL_WORKERS_PER_GATHER:-2}"
PG_MAX_PARALLEL_MAINTENANCE_WORKERS="${PG_MAX_PARALLEL_MAINTENANCE_WORKERS:-2}"

# Logging settings
PG_LOG_MIN_DURATION="${PG_LOG_MIN_DURATION:-1000}"
PG_LOG_STATEMENT="${PG_LOG_STATEMENT:-none}"
PG_LOG_LINE_PREFIX="${PG_LOG_LINE_PREFIX:-%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h }"

# =============================================================================
# Functions
# =============================================================================

log() {
  printf '[pg_config] %s\n' "$*"
}

# -----------------------------------------------------------------------------
# generate_postgresql_conf
# -----------------------------------------------------------------------------
# Generates postgresql.conf.
#
# Arguments:
#   $1 - Destination configuration file path.
#
# Returns:
#   0 - Success.
#   1 - Failure.
# -----------------------------------------------------------------------------
generate_postgresql_conf() {
  local conf_file="${1:?destination configuration file path is required}"

  log "Generating postgresql.conf: ${conf_file}"

  cat > "${conf_file}" << EOF
# =============================================================================
# PostgreSQL configuration file
# =============================================================================
# Generated automatically by postgres_config.sh
# Generated at: $(date -Iseconds)
# =============================================================================

# -----------------------------------------------------------------------------
# Connection settings
# -----------------------------------------------------------------------------
listen_addresses = '*'
max_connections = ${PG_MAX_CONNECTIONS}
port = ${PG_DB_PORT}

# -----------------------------------------------------------------------------
# Memory settings
# -----------------------------------------------------------------------------
# shared_buffers: database shared buffer cache.
# Recommendation: 25% of system memory, capped at 8GB for most deployments.
shared_buffers = ${PG_SHARED_BUFFERS}

# effective_cache_size: planner estimate for memory available to disk cache.
# Recommendation: 50-75% of system memory.
effective_cache_size = ${PG_EFFECTIVE_CACHE_SIZE}

# work_mem: memory used by each sort/hash operation.
# Note: one connection can use multiple work_mem allocations concurrently.
work_mem = ${PG_WORK_MEM}

# maintenance_work_mem: memory used by VACUUM, CREATE INDEX, and similar tasks.
maintenance_work_mem = ${PG_MAINTENANCE_WORK_MEM}

# -----------------------------------------------------------------------------
# WAL settings
# -----------------------------------------------------------------------------
# wal_level: WAL recording level.
# replica supports streaming replication and point-in-time recovery.
wal_level = replica

# wal_buffers: WAL buffer size.
# 16MB is sufficient for most workloads.
wal_buffers = ${PG_WAL_BUFFERS}

# max_wal_size: maximum WAL size before a checkpoint is triggered.
max_wal_size = ${PG_MAX_WAL_SIZE}

# min_wal_size: minimum WAL size retained.
min_wal_size = ${PG_MIN_WAL_SIZE}

# -----------------------------------------------------------------------------
# Checkpoint settings
# -----------------------------------------------------------------------------
# checkpoint_timeout: maximum time between checkpoints.
checkpoint_timeout = ${PG_CHECKPOINT_TIMEOUT}

# checkpoint_completion_target: spreads checkpoint writes across the interval.
# 0.9 means PostgreSQL should finish 90% of writes before the next checkpoint.
checkpoint_completion_target = ${PG_CHECKPOINT_COMPLETION_TARGET}

# -----------------------------------------------------------------------------
# Durability settings
# -----------------------------------------------------------------------------
# fsync: guarantees data is flushed to durable storage.
# Warning: production deployments should keep this enabled.
fsync = on

# synchronous_commit: commit durability mode.
# off: asynchronous commit, higher throughput, can lose recent committed data.
# on: synchronous commit, every commit is durable before returning success.
# For regenerable metadata, off is usually acceptable.
synchronous_commit = ${PG_SYNCHRONOUS_COMMIT}

# full_page_writes: required for crash recovery.
full_page_writes = on

# wal_compression: compresses full-page images in WAL.
wal_compression = on

# -----------------------------------------------------------------------------
# Query planner settings
# -----------------------------------------------------------------------------
# random_page_cost: cost of random page access.
# SSD: 1.1-1.4, HDD: 4.0.
random_page_cost = ${PG_RANDOM_PAGE_COST}

# seq_page_cost: baseline cost for sequential page access.
seq_page_cost = 1.0

# effective_io_concurrency: number of concurrent I/O operations.
# SSD: 200, HDD: 2.
effective_io_concurrency = ${PG_EFFECTIVE_IO_CONCURRENCY}

# default_statistics_target: statistics sampling precision.
# Higher values improve query plans but increase ANALYZE time.
default_statistics_target = ${PG_DEFAULT_STATISTICS_TARGET}

# -----------------------------------------------------------------------------
# Parallel query settings
# -----------------------------------------------------------------------------
# max_worker_processes: maximum number of background worker processes.
max_worker_processes = ${PG_MAX_WORKER_PROCESSES}

# max_parallel_workers: maximum parallel workers available to queries.
max_parallel_workers = ${PG_MAX_PARALLEL_WORKERS}

# max_parallel_workers_per_gather: maximum workers per Gather node.
max_parallel_workers_per_gather = ${PG_MAX_PARALLEL_WORKERS_PER_GATHER}

# max_parallel_maintenance_workers: maximum workers for maintenance operations.
max_parallel_maintenance_workers = ${PG_MAX_PARALLEL_MAINTENANCE_WORKERS}

# -----------------------------------------------------------------------------
# Logging settings
# -----------------------------------------------------------------------------
# log_destination: log output target.
log_destination = 'stderr'

# logging_collector: enables log collection.
logging_collector = on

# log_directory: log directory relative to the data directory.
log_directory = 'log'

# log_filename: log file name pattern.
log_filename = 'postgresql-%Y-%m-%d.log'

# log_rotation_age: log rotation period.
log_rotation_age = 1d

# log_rotation_size: log rotation size. 0 disables size-based rotation.
log_rotation_size = 0

# log_min_duration_statement: logs statements slower than this threshold in ms.
# -1 disables it, 0 logs all statements, >0 logs slow queries.
log_min_duration_statement = ${PG_LOG_MIN_DURATION}

# log_statement: statement classes to log.
# none: disabled, ddl: DDL statements, mod: data modification, all: all statements.
log_statement = '${PG_LOG_STATEMENT}'

# log_line_prefix: log line prefix.
log_line_prefix = '${PG_LOG_LINE_PREFIX}'

# log_timezone: log timezone.
log_timezone = 'Asia/Shanghai'

# -----------------------------------------------------------------------------
# Client defaults
# -----------------------------------------------------------------------------
# timezone: default session timezone.
timezone = 'Asia/Shanghai'

# lc_messages: message locale.
lc_messages = 'C.UTF-8'

# -----------------------------------------------------------------------------
# Lock management
# -----------------------------------------------------------------------------
# deadlock_timeout: deadlock detection timeout.
deadlock_timeout = 1s

# -----------------------------------------------------------------------------
# Autovacuum settings
# -----------------------------------------------------------------------------
autovacuum = on
autovacuum_max_workers = 3
autovacuum_naptime = 1min
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_scale_factor = 0.1
autovacuum_analyze_scale_factor = 0.05

# -----------------------------------------------------------------------------
# Extension settings
# -----------------------------------------------------------------------------
shared_preload_libraries = 'vchord'

# -----------------------------------------------------------------------------
# zhparser settings (Chinese full-text search parser)
# -----------------------------------------------------------------------------
# punctuation_ignore: ignore punctuation tokens.
zhparser.punctuation_ignore = on

# seg_with_duality: segment loose single characters with duality.
zhparser.seg_with_duality = on

EOF

  log "postgresql.conf generated"
}

# -----------------------------------------------------------------------------
# generate_pg_hba_conf
# -----------------------------------------------------------------------------
# Generates pg_hba.conf.
#
# Arguments:
#   $1 - Destination configuration file path.
#
# Returns:
#   0 - Success.
#   1 - Failure.
# -----------------------------------------------------------------------------
generate_pg_hba_conf() {
  local conf_file="${1:?destination configuration file path is required}"

  log "Generating pg_hba.conf: ${conf_file}"

  cat > "${conf_file}" << 'EOF'
# =============================================================================
# PostgreSQL client authentication configuration file
# =============================================================================
# Generated automatically by postgres_config.sh
# All connections use SCRAM-SHA-256 password authentication.
#
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# -----------------------------------------------------------------------------

# Local Unix socket connections
local   all             all                                     scram-sha-256

# IPv4 local connections
host    all             all             127.0.0.1/32            scram-sha-256

# IPv6 local connections
host    all             all             ::1/128                 scram-sha-256

# IPv4 all addresses for Docker network and external clients
host    all             all             0.0.0.0/0               scram-sha-256

# IPv6 all addresses
host    all             all             ::/0                    scram-sha-256
EOF

  log "pg_hba.conf generated"
}

# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
# Generates all configuration files.
#
# Arguments:
#   $1 - PostgreSQL data directory path.
#   $2 - PostgreSQL system user. Optional, defaults to postgres.
#
# Returns:
#   0 - Success.
#   1 - Failure.
# -----------------------------------------------------------------------------
main() {
  local pg_data_dir="${1:?PostgreSQL data directory is required}"
  local pg_user="${2:-postgres}"

  log "Starting PostgreSQL configuration generation"
  log "Data directory: ${pg_data_dir}"
  log "System user: ${pg_user}"

  log "Configuration parameters:"
  log "  - shared_buffers: ${PG_SHARED_BUFFERS}"
  log "  - effective_cache_size: ${PG_EFFECTIVE_CACHE_SIZE}"
  log "  - work_mem: ${PG_WORK_MEM}"
  log "  - max_connections: ${PG_MAX_CONNECTIONS}"
  log "  - synchronous_commit: ${PG_SYNCHRONOUS_COMMIT}"
  log "  - max_wal_size: ${PG_MAX_WAL_SIZE}"

  generate_postgresql_conf "${pg_data_dir}/postgresql.conf"
  generate_pg_hba_conf "${pg_data_dir}/pg_hba.conf"

  chown "${pg_user}:${pg_user}" "${pg_data_dir}/postgresql.conf"
  chown "${pg_user}:${pg_user}" "${pg_data_dir}/pg_hba.conf"

  log "PostgreSQL configuration generation completed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
