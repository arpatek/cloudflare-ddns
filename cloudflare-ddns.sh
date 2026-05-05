#!/bin/bash
# =============================================================================
# Script Name: cloudflare-ddns
# Description: Dynamic DNS updater for Cloudflare. Detects current public IP
#              and reconciles it with a Cloudflare A record. Uses a controller
#              loop pattern with validation, API checks, and safe updates.
#
# Author: Juan Garcia (arpatek)
# Created: 2026-04-12
# Version: 1.2
# =============================================================================

set -euo pipefail

# ──[ Required Environment Variables ]─────────────────────────────────────────
: "${ZONE_ID:?missing}"
: "${RECORD_TYPE:?missing}"
: "${RECORD_ID:?missing}"
: "${RECORD_NAME:?missing}"
: "${API_TOKEN:?missing}"
: "${TTL_DUR:=120}"

# ──[ Logging ]────────────────────────────────────────────────────────────────
log_base() {
    local level="$1"
    local priority="$2"
    shift 2
    logger -t cloudflare-ddns -p "$priority" "[$level] $*"
}

log()  { log_base INFO  user.info    "$@"; }
warn() { log_base WARN  user.warning "$@"; }
error(){ log_base ERROR user.err     "$@"; }

# ──[ Required Parameters ]────────────────────────────────────────────────────
if ! echo "$TTL_DUR" | grep -qE '^[0-9]+$'; then
    error "TTL_DUR must be a positive integer (got: $TTL_DUR)"
    exit 1
fi

# ──[ Required Dependencies ]──────────────────────────────────────────────────
for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || {
        error "Missing dependency: $cmd"
        exit 1
    }
done

# ──[ IP Validation ]──────────────────────────────────────────────────────────
VALID_IP_RE='^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

is_valid_ip() {
    echo "$1" | grep -qE "$VALID_IP_RE"
}

# ──[ Public IP Discovery ]────────────────────────────────────────────────────
log "Fetching public IP from ipify"
IP_IPIFY=$(
    curl -fsS --max-time 10 https://api.ipify.org
) || {
    error "Failed to contact ipify API"
    exit 1
}

if ! is_valid_ip "$IP_IPIFY"; then
    error "Invalid IP from ipify: $IP_IPIFY"
    exit 1
fi

log "Fetching public IP from AWS checkip"
IP_AWS=$(
    curl -fsS --max-time 10 https://checkip.amazonaws.com
) || {
    error "Failed to contact AWS checkip API"
    exit 1
}

if ! is_valid_ip "$IP_AWS"; then
    error "Invalid IP from AWS checkip: $IP_AWS"
    exit 1
fi

if [ "$IP_IPIFY" != "$IP_AWS" ]; then
    error "IP source disagreement: ipify=$IP_IPIFY aws=$IP_AWS — aborting to avoid bad update"
    exit 1
fi

CURRENT_IP="$IP_IPIFY"
log "Public IP confirmed: $CURRENT_IP (ipify and AWS agree)"

# ──[ Cloudflare DNS Record Fetch ]────────────────────────────────────────────
log "Fetching DNS record: $RECORD_NAME ($RECORD_ID)"
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
    error "Could not extract DNS IP from GET response"
    exit 1
fi

log "Current DNS record: $RECORD_NAME → $DNS_IP"

# ──[ State Comparison ]──────────────────────────────────────────────────────
if [ "$CURRENT_IP" = "$DNS_IP" ]; then
    log "No update needed: $RECORD_NAME is already $CURRENT_IP"
    exit 0
fi

log "IP change detected: $DNS_IP → $CURRENT_IP — updating $RECORD_NAME"

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

# ──[ Success ]────────────────────────────────────────────────────────────────
log "Successfully updated $RECORD_NAME: $DNS_IP → $CURRENT_IP"
