#!/bin/bash

# Data directory where MySQL database files live. The data subdirectory is here
# because .bashrc and my.cnf both live in /var/lib/mysql/ and we don't want a
# volume to override it.
export MYSQL_DATADIR=/var/lib/mysql/data

# Configuration settings.
export MYSQL_DEFAULTS_FILE=/etc/my.cnf
export MYSQL_LOWER_CASE_TABLE_NAMES=${MYSQL_LOWER_CASE_TABLE_NAMES:-0}
export MYSQL_MAX_CONNECTIONS=${MYSQL_MAX_CONNECTIONS:-151}
export MYSQL_FT_MIN_WORD_LEN=${MYSQL_FT_MIN_WORD_LEN:-4}
export MYSQL_FT_MAX_WORD_LEN=${MYSQL_FT_MAX_WORD_LEN:-20}
export MYSQL_AIO=${MYSQL_AIO:-1}

# Be paranoid and stricter than we should be.
# https://dev.mysql.com/doc/refman/en/identifiers.html
mysql_identifier_regex='^[a-zA-Z0-9_]+$'
mysql_password_regex='^[a-zA-Z0-9_~!@#$%^&*()-=<>,.?;:|]+$'

# Variables that are used to connect to local mysql during initialization
mysql_flags="-u root --socket=/tmp/mysql.sock"
admin_flags="--defaults-file=$MYSQL_DEFAULTS_FILE $mysql_flags"

MYSQL_TARGET_MASTER_SERVICE_HOST=${!MYSQL_TARGET_MASTER_SERVICE_NAME}

# Make sure env variables don't propagate to mysqld process.
function unset_env_vars() {
  unset MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE MYSQL_ROOT_PASSWORD
}

# Poll until MySQL responds to our ping.
function wait_for_mysql() {
  pid=$1 ; shift

  while [ true ]; do
    if [ -d "/proc/$pid" ]; then
      mysqladmin --socket=/tmp/mysql.sock ping &>/dev/null && return 0
    else
      return 1
    fi
    echo "Waiting for MySQL to start ..."
    sleep 1
  done
}

function start_local_mysql() {
  # Now start mysqld and add appropriate users.
  echo 'Starting local mysqld server ...'
  ${MYSQL_PREFIX}/libexec/mysqld \
    --defaults-file=$MYSQL_DEFAULTS_FILE \
    --skip-networking --socket=/tmp/mysql.sock "$@" &
  mysql_pid=$!
  wait_for_mysql $mysql_pid
}

# Initialize the MySQL database (create user accounts and the initial database)
function initialize_database() {
  echo 'Running mysql_install_db ...'
  # Using --rpm since we need mysql_install_db behaves as in RPM
  mysql_install_db --rpm --datadir=$MYSQL_DATADIR
  start_local_mysql "$@"

  [ -v MYSQL_RUNNING_AS_SLAVE ] && return

  # Do not care what option is compulsory here, just create what is specified
  if [ -v MYSQL_USER ]; then
mysql $mysql_flags <<EOSQL
    CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
    CREATE USER 'haproxy_check'@'%';
EOSQL
  fi

  if [ -v MYSQL_DATABASE ]; then
    mysqladmin $admin_flags create "${MYSQL_DATABASE}"

    if [ -v MYSQL_USER ]; then
mysql $mysql_flags <<EOSQL
      GRANT ALL ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%' ;
      FLUSH PRIVILEGES ;
EOSQL
    fi
  fi

  if [ -v MYSQL_ROOT_PASSWORD ]; then
mysql $mysql_flags <<EOSQL
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
EOSQL
  fi
}

# The 'server_id' number for slave needs to be within 1-4294967295 range.
# This function will take the 'hostname' if the container, hash it and turn it
# into the number.
# See: https://dev.mysql.com/doc/refman/en/replication-options.html#option_mysqld_server-id
function server_id() {
  checksum=$(sha256sum <<< $(hostname -i))
  checksum=${checksum:0:14}
  echo -n $((0x${checksum}%4294967295))
}

function wait_for_mysql_master() {
  while true; do
    echo "Waiting for MySQL master (${MYSQL_MASTER_SERVICE_NAME}) to accept connections ..."
    mysqladmin --host=${MYSQL_MASTER_SERVICE_NAME} --user="${MYSQL_MASTER_USER}" \
      --password="${MYSQL_MASTER_PASSWORD}" ping &>/dev/null && return 0
    sleep 1
  done
}

function wait_for_target_mysql_master() {
  while true; do
    echo "Waiting for MySQL master (${MYSQL_TARGET_MASTER_SERVICE_HOST}) to accept connections ..."
    mysqladmin --host=${MYSQL_TARGET_MASTER_SERVICE_HOST} --user="${MYSQL_MASTER_USER}" \
      --password="${MYSQL_MASTER_PASSWORD}" ping &>/dev/null && return 0
    sleep 1
  done
}


