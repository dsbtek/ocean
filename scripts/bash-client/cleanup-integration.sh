#!/usr/bin/env bash

# NOTE: This file can be either sourced or executed.
# If executed, it'll need the ENV vars of `base-port-client.sh` as well.

## Requires the following ENV vars:
#
# INTEGRATION_IDENTIFIER
# BLUEPRINT_IDENTIFIERS - space separated array of blueprint ids
#
(return 0 2>/dev/null) && SOURCED=1 || SOURCED=0
if [[ ${SOURCED} -eq 0 ]]; then
    SCRIPT_BASE="$(cd -P "$(dirname "$0")" && pwd)"
else
    SCRIPT_BASE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "${INTEGRATION_IDENTIFIER}" ]]; then
    echo "Missing INTEGRATION_IDENTIFIER"
    exit 1
fi

if [[ -z "${BLUEPRINT_IDENTIFIERS}" ]]; then
    echo "Missing BLUEPRINT_IDENTIFIERS"
    exit 1
fi

if [[ $(type -t _call_port_api) != function ]]; then
    source "${SCRIPT_BASE}/base-port-client.sh"
fi

_wait_for_migration() {
    MIGRATION_ID=${1}
    _debug "Waiting for migration to finish ${MIGRATION_ID}"
    STATUS="UNKNOWN"
    RETRIES=25
    TIMEOUT=3
    until [[ "${STATUS}" == "COMPLETED" || ${RETRIES} == 0 ]]; do
        _debug "Polling migration ${MIGRATION_ID} - Retries left: ${RETRIES}"
        STATUS=$(_call_port_api "migrations/${MIGRATION_ID}" | jq -r '.migration.status')
        if [[ "${STATUS}" != "COMPLETED" ]]; then
            _debug "Migration status ${STATUS}, waiting"
            sleep ${TIMEOUT}
        fi
        ((RETRIES--))
    done
}

_cleanup_blueprint() {
    BLUEPRINT=${1}
    GET_RESULT=$(_call_port_api "blueprints/${BLUEPRINT}")
    RESULT_STATUS=$(echo "${GET_RESULT}" | jq -r '.ok')
    if [[ "${RESULT_STATUS}" == "true" ]]; then
        echo "Cleaning up blueprint ${BLUEPRINT} entities"
        DELETE_ALL_ENTITIES_RESULT=$(_call_port_api "blueprints/${BLUEPRINT}/all-entities" "DELETE")
        if [[ "$(echo "${DELETE_ALL_ENTITIES_RESULT}" | jq -r '.ok')" == "true" ]]; then
            MIGRATION_ID=$(echo "${DELETE_ALL_ENTITIES_RESULT}" | jq -r '.migrationId')
            _wait_for_migration "${MIGRATION_ID}"
        elif [[ "$(echo "${DELETE_ALL_ENTITIES_RESULT}" | jq '.error')" == "other_migration_running_on_blueprint" ]]; then
            MIGRATION_ID=$(echo "${DELETE_ALL_ENTITIES_RESULT}" | jq -r '.details | .otherMigrationId')
            _wait_for_migration "${MIGRATION_ID}"
        fi
        echo "Deleting blueprint ${BLUEPRINT}"
        _call_port_api "blueprints/${BLUEPRINT}" DELETE >/dev/null
    else
        echo "Blueprint ${BLUEPRINT} not found, skipping cleanup"
    fi
}

_cleanup() {
    echo "Cleaning up ${INTEGRATION_IDENTIFIER} with blueprints: ${BLUEPRINT_IDENTIFIERS[*]}"
    for BLUEPRINT in ${BLUEPRINT_IDENTIFIERS}; do
        _cleanup_blueprint "${BLUEPRINT}"
    done
    echo "Deleting the integration ${INTEGRATION_IDENTIFIER}"
    _call_port_api "integration/{$INTEGRATION_IDENTIFIER}" DELETE >/dev/null
    echo "Finished cleanup"
}

if [[ ${SOURCED} == 0 ]]; then
    _cleanup
fi
