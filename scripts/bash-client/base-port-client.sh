#!/usr/bin/env bash

# NOTE: This file should be sourced, not executed

# Requires the following ENV vars:
#
# PORT_CLIENT_ID
# PORT_CLIENT_SECRET
#
# Optional ENV vars:
# PORT_BASE_URL (defaults to 'https://api.getport.io')
# VERBOSE (set to log all url calls to stderr)

if [[ -z "${PORT_CLIENT_ID}" ]]; then
    echo "Missing PORT_CLIENT_ID env var"
    exit 1
fi

if [[ -z "${PORT_CLIENT_SECRET}" ]]; then
    echo "Missing PORT_CLIENT_SECRET env var"
    exit 1
fi

PORT_BASE_URL=${PORT_BASE_URL:-'https://api.getport.io'}
VERBOSE=${VERBOSE:-0}

ACCESS_TOKEN_RESULT=$(curl -s -X 'POST' \
    "${PORT_BASE_URL}/v1/auth/access_token" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "{\"clientId\": \"${PORT_CLIENT_ID}\", \"clientSecret\": \"${PORT_CLIENT_SECRET}\" }")

ACCESS_TOKEN=$(echo "${ACCESS_TOKEN_RESULT}" | jq -r '.accessToken')

AUTH_HEADER="Authorization: Bearer ${ACCESS_TOKEN}"

_debug() {
    if [[ ${VERBOSE} != 0 ]]; then
        echo "$@" >&2
    fi
}

_call_port_api() {
    URL="${1}"
    shift 1
    METHOD="GET"
    if [[ "${1:-NOPE}" != "NOPE" ]]; then
        METHOD="${1}"
        shift 1
    fi

    _debug "Calling ${METHOD} ${PORT_BASE_URL}/v1/${URL}"

    URL_RESULT=$(curl -s -X "${METHOD}" \
        "${PORT_BASE_URL}/v1/${URL}" \
        -H 'accept: */*' \
        -H "${AUTH_HEADER}" \
        "$@")

    _debug "API Result: \n${URL_RESULT}\n"
    echo "${URL_RESULT}"
}
