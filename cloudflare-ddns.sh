#!/bin/bash
# =============================================================================
# Script Name: cloudflare-ddns
# Description: Dynamic DNS updater for Cloudflare. Detects current public IP
#              and reconciles it with a Cloudflare A record. Uses a controller
#              loop pattern with validation, API checks, and safe updates.
#
# Author: Juan Garcia (arpatek)
# Created: 2026-04-12
# Version: 1.0
# =============================================================================

set -euo pipefail

# ──[ Required Environment Variables ]─────────────────────────────────────────
: "${ZONE_ID:?missing}"
: "${RECORD_TYPE:?missing}"
: "${RECORD_ID:?missing}"
: "${RECORD_NAME:?missing}"
: "${API_TOKEN:?missing}"
: "${TTL_DUR:=120}"

# ──[ String Decoration Functions ]────────────────────────────────────────────
log_base() {
    local level="$1"
    local priority="$2"
    shift 2
    logger -t cloudflare-ddns -p "$priority" "[$level] $*"
}

log() {
    log_base INFO user.info "$@"
}

error() {
    log_base ERROR user.err "$@"
}

# ──[ Required Parameters ]────────────────────────────────────────────────────
if ! echo "$TTL_DUR" | grep -qE '^[0-9]+$'; then
    error "TTL_DUR must be a positive integer (got: $TTL_DUR)"
    exit 1
fi

# ──[ Required Dependencies ]──────────────────────────────────────────────────
# This script requires the following binaries:
#   - curl   : HTTP requests to ipify and Cloudflare API
#   - jq     : JSON parsing of API responses
#
# Install on Debian/Ubuntu:
#   apt install curl jq
#
# Install on RHEL/CentOS:
#   dnf install curl jq
# ─────────────────────────────────────────────────────────────────────────────
for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "Missing dependency: $cmd"
        exit 1
    }
done

# ──[ Public IP Discovery ]────────────────────────────────────────────────────
CURRENT_IP=$(
    curl -fsS --max-time 10 https://api.ipify.org
) || {
    error "Failed to contact ipify API"
    exit 1
}

if ! echo "$CURRENT_IP" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    error "Invalid IP received: $CURRENT_IP"
    exit 1
fi

# ──[ Cloudflare DNS Record Fetch ]────────────────────────────────────────────
GET_RESPONSE=$(
    curl -fsS --max-time 10 -X GET \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json"
) || {
    error "Failed to contact Cloudflare API (GET)"
    exit 1
}

GET_SUCCESS="$(
    echo "$GET_RESPONSE" | jq -r '.success // false'
)"

if [ "$GET_SUCCESS" != "true" ]; then
    error "Cloudflare API error (GET): $(jq -c '.' <<<"$GET_RESPONSE")"
    exit 1
fi

DNS_IP="$(
    echo "$GET_RESPONSE" | jq -r '.result.content // empty'
)"

if [ -z "$DNS_IP" ]; then
    error "Could not extract DNS IP from response"
    exit 1
fi

# ──[ State Comparison ]──────────────────────────────────────────────────────
if [ "$CURRENT_IP" = "$DNS_IP" ]; then
    log "No change: current_ip=$CURRENT_IP"
    exit 0
fi

log "Updating IP: dns_ip=$DNS_IP → target_ip=$CURRENT_IP"

# ──[ Cloudflare DNS Update ]──────────────────────────────────────────────────
DNS_PROXIED="$(echo "$GET_RESPONSE" | jq -r '.result.proxied // false')"

PAYLOAD=$(jq -n \
    --arg name "$RECORD_NAME" \
    --arg ip "$CURRENT_IP" \
    --arg type "$RECORD_TYPE" \
    --argjson ttl "$TTL_DUR" \
    --argjson proxied "$DNS_PROXIED" \
    '{type:$type, name:$name, content:$ip, ttl:$ttl, proxied:$proxied}')

PUT_RESPONSE=$(
    curl -fsS --max-time 10 -X PUT \
        "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        --data "$PAYLOAD"
) || {
    error "Failed to contact Cloudflare API (PUT)"
    exit 1
}

PUT_SUCCESS="$(
    echo "$PUT_RESPONSE" | jq -r '.success // false'
)"

if [ "$PUT_SUCCESS" != "true" ]; then
    error "Cloudflare update failed (PUT): $(jq -c '.' <<<"$PUT_RESPONSE")"
    exit 1
fi

# ──[ Success Output ]─────────────────────────────────────────────────────────
log "Cloudflare record updated to: $CURRENT_IP"

