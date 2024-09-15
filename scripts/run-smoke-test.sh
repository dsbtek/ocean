#!/usr/bin/env bash

# Requires docker and the following ENV vars:
#
# PORT_CLIENT_ID
# PORT_CLIENT_SECRET
# PORT_BASE_URL (optional, defaults to 'https://api.getport.io')
#

SCRIPT_BASE="$(cd -P "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd -P "${SCRIPT_BASE}/../" && pwd)"

RANDOM_ID="${RANDOM}${RANDOM}" # DOGE - RANDOM
INTEGRATION_IDENTIFIER="smoke-test-integration-${RANDOM_ID}"
BLUEPRINT_DEPARTMENT="fake-department-${RANDOM_ID}"
BLUEPRINT_PERSON="fake-person-${RANDOM_ID}"
BLUEPRINT_IDENTIFIERS="${BLUEPRINT_DEPARTMENT} ${BLUEPRINT_PERSON}"
PORT_BASE_URL_FOR_DOCKER=${PORT_BASE_URL}

if [[ ${PORT_BASE_URL} =~ localhost ]]; then
    # NOTE: This is to support running this script on a local docker.
    # It allows the container to access Port API running on the docker host.
    PORT_BASE_URL_FOR_DOCKER=${PORT_BASE_URL//localhost/host.docker.internal}
fi


# NOTE: Make the blueprints and mapping immutable by adding a random suffix
TEMP_DIR=$(mktemp -d -t smoke-test-integration.XXXXXXX)
RESOURCE_DIR_SUFFIX="integrations/fake-integration/.port/resources"
cp -r "${ROOT_DIR}"/${RESOURCE_DIR_SUFFIX} "${TEMP_DIR}"

sed -i.bak "s/fake-department/${BLUEPRINT_DEPARTMENT}/g" "${TEMP_DIR}"/resources/blueprints.json
sed -i.bak "s/fake-person/${BLUEPRINT_PERSON}/g" "${TEMP_DIR}"/resources/blueprints.json
sed -i.bak "s/\"fake-department\"/\"${BLUEPRINT_DEPARTMENT}\"/g" "${TEMP_DIR}"/resources/port-app-config.yml
sed -i.bak "s/\"fake-person\"/\"${BLUEPRINT_PERSON}\"/g" "${TEMP_DIR}"/resources/port-app-config.yml

source "${SCRIPT_BASE}/bash-client/base-port-client.sh"
source "${SCRIPT_BASE}/bash-client/cleanup-integration.sh"

echo "Authenticated with Port, cleaning up previous runs"

_cleanup

TAR_FULL_PATH=$(ls "${ROOT_DIR}"/dist/*.tar.gz)
if [[ $? != 0 ]]; then
    echo "Build file not found, run 'make build' once first!"
    exit 1
fi
TAR_FILE=$(basename "${TAR_FULL_PATH}")

echo "Found release ${TAR_FILE}, triggering fake integration with ID: '${INTEGRATION_IDENTIFIER}'"

# NOTE: Runs the fake integration with the modified blueprints and install the current core for a single sync
docker run --rm -i \
    --entrypoint 'bash' \
    -v "${TAR_FULL_PATH}:/opt/dist/${TAR_FILE}" \
    -v "${TEMP_DIR}/resources:/app/.port/resources" \
    -e OCEAN__PORT__BASE_URL="${PORT_BASE_URL_FOR_DOCKER}" \
    -e OCEAN__PORT__CLIENT_ID="${PORT_CLIENT_ID}" \
    -e OCEAN__PORT__CLIENT_SECRET="${PORT_CLIENT_SECRET}" \
    -e OCEAN__EVENT_LISTENER='{"type": "POLLING"}' \
    -e OCEAN__INTEGRATION__TYPE="smoke-test" \
    -e OCEAN__INTEGRATION__IDENTIFIER="${INTEGRATION_IDENTIFIER}" \
    --name=ZOMG-TEST \
    ghcr.io/port-labs/port-ocean-fake-integration:0.1.1-dev \
    -c "pip install --root-user-action=ignore /opt/dist/${TAR_FILE}[cli] && ocean sail -O"

echo "Integration finished successfully, verifying entities"

# NOTE: Gather all the needed results to assert on
INTEGRATION_RESULT="$(_call_port_api "integration/${INTEGRATION_IDENTIFIER}?byField=installationId")"
INTEGRATION_DETAILS=$(echo "${INTEGRATION_RESULT}" | jq -r '.integration')
INTEGRATION_RESYNC_STATE_STATUS=$(echo "${INTEGRATION_DETAILS}" | jq -r '.resyncState | .status')
ENTITIES_SEARCH_RESULT_DEPARTMENTS=$(_call_port_api "blueprints/${BLUEPRINT_DEPARTMENT}/entities?exclude_calculated_properties=false&attach_title_to_relation=false")
ENTITIES_SEARCH_RESULT_PERSONS=$(_call_port_api "blueprints/${BLUEPRINT_PERSON}/entities?exclude_calculated_properties=false&attach_title_to_relation=false")

echo "Done, cleaning up"

_cleanup

echo "Starting assertions"

if [[ "${INTEGRATION_RESYNC_STATE_STATUS}" != "completed" ]]; then
    echo "Integration did not complete sync"
    exit 1
fi

if [[ "$(echo "${ENTITIES_SEARCH_RESULT_DEPARTMENTS}" | jq -r '.entities | length')" != "0" ]]; then
    echo "Found enough entities for static departments"
else
    echo "DID NOT find enough entities for fake departments"
    exit 1
fi

if [[ "$(echo "${ENTITIES_SEARCH_RESULT_PERSONS}" | jq -r '.entities | length')" != "0" ]]; then
    echo "Found enough fake persons, verifying per department:"
    for DEPARTMENT in $(echo "${ENTITIES_SEARCH_RESULT_DEPARTMENTS}" | jq -r '.entities | .[] | .identifier'); do
        RESULT=$(echo "${ENTITIES_SEARCH_RESULT_PERSONS}" | jq -r ".entities | .[] | .relations | select(.department==\"${DEPARTMENT}\") | length")
        if [[ "${RESULT}" == "0" ]]; then
            echo "Did not find enough fake persons for department: ${DEPARTMENT}"
            exit 1
        else
            echo "Found enough fake persons for department: ${DEPARTMENT}"
        fi
    done
else
    echo "DID NOT find enough entities for fake persons"
    exit 1
fi

echo "Happy sailing!"
