#!/usr/bin/env bash

# User-provided configuration must always be respected.
#
# Therefore, this script must only derives Airflow AIRFLOW__ variables from other variables
# when the user did not provide their own configuration.

TRY_LOOP="20"

# Global defaults and back-compat
: "${AIRFLOW_HOME:="/usr/local/airflow"}"
: "${AIRFLOW__CORE__FERNET_KEY:=${FERNET_KEY:="_ZqQBBLOOKbgcGMe30_sN3FlDAXFVIa2sYe3dceDExE="}}"
: "${AIRFLOW__CORE__EXECUTOR:=${EXECUTOR:-Celery}Executor}"

# Load DAGs examples (default: Yes)
if [[ -z "$AIRFLOW__CORE__LOAD_EXAMPLES" && "${LOAD_EX:=n}" == n ]]; then
  AIRFLOW__CORE__LOAD_EXAMPLES=False
fi

export \
  AIRFLOW_HOME \
  AIRFLOW__CORE__EXECUTOR \
  AIRFLOW__CORE__FERNET_KEY \
  AIRFLOW__CORE__LOAD_EXAMPLES \

# Install custom python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(command -v pip) install --user -r /requirements.txt
fi

wait_for_port() {
  local name="$1" host="$2" port="$3"
  local j=0
  echo "host:$host and port:$port"
  while ! nc -z "$host" "$port" >/dev/null 2>&1 < /dev/null; do
    j=$((j+1))
    if [ $j -ge $TRY_LOOP ]; then
      echo >&2 "$(date) - $host:$port still not reachable, giving up"
      exit 1
    fi
    echo "$(date) - waiting for $name... $j/$TRY_LOOP"
    sleep 5
  done
}

# Other executors than SequentialExecutor drive the need for an SQL database, here PostgreSQL is used
if [ "$AIRFLOW__CORE__EXECUTOR" != "SequentialExecutor" ]; then
  # Check if the user has provided explicit Airflow configuration concerning the database
  if [ -z "$AIRFLOW__CORE__SQL_ALCHEMY_CONN" ]; then
    # Default values corresponding to the default compose files
    : "${MYSQL_HOST:="192.168.0.2"}"
    : "${MYSQL_PORT:="3306"}"
    : "${MYSQL_USER:="airflow"}"
    : "${MYSQL_PASSWORD:="airflow"}"
    : "${MYSQL_DB:="airflow"}"
    : "${MYSQL_EXTRAS:-""}"

    AIRFLOW__CORE__SQL_ALCHEMY_CONN="mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}${MYSQL_EXTRAS}"
    export AIRFLOW__CORE__SQL_ALCHEMY_CONN

    # Check if the user has provided explicit Airflow configuration for the broker's connection to the database
    if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
      AIRFLOW__CELERY__RESULT_BACKEND="mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@${MYSQL_HOST}:${MYSQL_PORT}/${MYSQL_DB}${MYSQL_EXTRAS}"
      export AIRFLOW__CELERY__RESULT_BACKEND
    fi
  else
    if [[ "$AIRFLOW__CORE__EXECUTOR" == "CeleryExecutor" && -z "$AIRFLOW__CELERY__RESULT_BACKEND" ]]; then
      >&2 printf '%s\n' "FATAL: if you set AIRFLOW__CORE__SQL_ALCHEMY_CONN manually with CeleryExecutor you must also set AIRFLOW__CELERY__RESULT_BACKEND"
      exit 1
    fi

    # Derive useful variables from the AIRFLOW__ variables provided explicitly by the user
    MYSQL_ENDPOINT=$(echo -n "$AIRFLOW__CORE__SQL_ALCHEMY_CONN" | cut -d '/' -f3 | sed -e 's,.*@,,')
    MYSQL_HOST=$(echo -n "$MYSQL_ENDPOINT" | cut -d ':' -f1)
    MYSQL_PORT=$(echo -n "$MYSQL_ENDPOINT" | cut -d ':' -f2)
  fi

  wait_for_port "Mysql" "$MYSQL_HOST" "$MYSQL_PORT"
fi

# CeleryExecutor drives the need for a Celery broker, here Redis is used
if [ "$AIRFLOW__CORE__EXECUTOR" = "CeleryExecutor" ]; then
  # Check if the user has provided explicit Airflow configuration concerning the broker
  if [ -z "$AIRFLOW__CELERY__BROKER_URL" ]; then
    # Default values corresponding to the default compose files
    : "${REDIS_PROTO:="redis://"}"
    : "${REDIS_HOST:="redis"}"
    : "${REDIS_PORT:="6379"}"
    : "${REDIS_PASSWORD:=""}"
    : "${REDIS_DBNUM:="1"}"

    # When Redis is secured by basic auth, it does not handle the username part of basic auth, only a token
    if [ -n "$REDIS_PASSWORD" ]; then
      REDIS_PREFIX=":${REDIS_PASSWORD}@"
    else
      REDIS_PREFIX=
    fi

    AIRFLOW__CELERY__BROKER_URL="${REDIS_PROTO}${REDIS_PREFIX}${REDIS_HOST}:${REDIS_PORT}/${REDIS_DBNUM}"
    export AIRFLOW__CELERY__BROKER_URL
  else
    # Derive useful variables from the AIRFLOW__ variables provided explicitly by the user
    REDIS_ENDPOINT=$(echo -n "$AIRFLOW__CELERY__BROKER_URL" | cut -d '/' -f3 | sed -e 's,.*@,,')
    REDIS_HOST=$(echo -n "$REDIS_ENDPOINT" | cut -d ':' -f1)
    REDIS_PORT=$(echo -n "$REDIS_ENDPOINT" | cut -d ':' -f2)
  fi

  wait_for_port "Redis" "$REDIS_HOST" "$REDIS_PORT"
fi

case "$1" in
  webserver)
    airflow initdb
    if [ "$AIRFLOW__CORE__EXECUTOR" = "LocalExecutor" ] || [ "$AIRFLOW__CORE__EXECUTOR" = "SequentialExecutor" ]; then
      # With the "Local" and "Sequential" executors it should all run in one container.
      airflow scheduler &
    fi
    exec airflow webserver
    ;;
  worker|scheduler)
    # Give the webserver time to run initdb.
    sleep 10
    exec airflow "$@"
    ;;
  flower)
    sleep 10
    exec airflow "$@"
    ;;
  version)
    exec airflow "$@"
    ;;
  *)
    # The command is something like bash, not an airflow subcommand. Just run it in the right environment.
    exec "$@"
    ;;
esac