#!/usr/bin/env bash
#
# Install every single-install TIBCO Developer Hub Marketplace entry.
#
# Does what clicking "Get" + "I Agree" does in the Marketplace UI, for all entries at once:
#   1. lists the Marketplace entries (Templates tagged `devhub-marketplace`) from the catalog
#   2. skips multi-install entries (metadata["tibco.developer.hub/marketplace"].isMultiInstall,
#      e.g. "Platform APIs") — those need a choice (a platform version) and can be run many times
#   3. skips entries that are already installed (same check as the Marketplace page)
#   4. runs each remaining entry's template with `accept: true` and waits for the task to finish
#
# Usage:
#   ./install-marketplace-entries.sh [DEV_HUB_URL]
#
#   DEV_HUB_URL  URL the backend API is served under (default: http://localhost:7007)
#                e.g. https://tibco-developer-hub-demo.developer-experience.dataplanes.pro/tibco/hub
#
# Environment:
#   DEV_HUB_TOKEN  Backstage token to call the API with. When unset a guest token is requested
#                  from /api/auth/guest/refresh (works when the guest provider is enabled).
#   DRY_RUN=1      only list what would be installed, install nothing
#   TASK_TIMEOUT   seconds to wait for each install task (default: 180)
#
# Requires: curl, jq

set -euo pipefail

DEV_HUB_URL="${1:-${DEV_HUB_URL:-http://localhost:7007}}"
DEV_HUB_URL="${DEV_HUB_URL%/}"
DEV_HUB_TOKEN="${DEV_HUB_TOKEN:-}"
DRY_RUN="${DRY_RUN:-0}"
TASK_TIMEOUT="${TASK_TIMEOUT:-180}"

for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: '$bin' is required but not installed." >&2; exit 1; }
done

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

# api METHOD PATH [JSON_BODY] -> response body in $BODY_FILE, HTTP status code on stdout
api() {
  local method="$1" path="$2" data="${3:-}"
  local args=(-sS -o "$BODY_FILE" -w '%{http_code}' -X "$method" "$DEV_HUB_URL$path"
    -H "Accept: application/json")
  [[ -n "$DEV_HUB_TOKEN" ]] && args+=(-H "Authorization: Bearer $DEV_HUB_TOKEN")
  [[ -n "$data" ]] && args+=(-H "Content-Type: application/json" --data "$data")
  curl "${args[@]}" || true
}

# api_ok METHOD PATH [JSON_BODY] -> fails the script unless the call returns 2xx
api_ok() {
  local code
  code="$(api "$@")"
  if [[ "$code" != 2* ]]; then
    echo "ERROR: $1 $2 returned HTTP $code: $(head -c 500 "$BODY_FILE")" >&2
    exit 1
  fi
}

echo "TIBCO Developer Hub: $DEV_HUB_URL"

# --- 1. Token -------------------------------------------------------------------------------
if [[ -z "$DEV_HUB_TOKEN" ]]; then
  code="$(api GET /api/auth/guest/refresh)"
  DEV_HUB_TOKEN="$(jq -r '.backstageIdentity.token // empty' "$BODY_FILE" 2>/dev/null || true)"
  if [[ "$code" != 200 || -z "$DEV_HUB_TOKEN" ]]; then
    echo "ERROR: could not get a guest token (HTTP $code). Set DEV_HUB_TOKEN to a Backstage token." >&2
    exit 1
  fi
  echo "Using a guest token."
fi

# --- 2. List the Marketplace entries ------------------------------------------------------------
FIELDS='kind,metadata.name,metadata.namespace,metadata.title,metadata.tibco.developer.hub/marketplace'
entries='[]'
query="/api/catalog/entities/by-query?filter=kind=template,metadata.tags=devhub-marketplace&limit=200&fields=$FIELDS"
while :; do
  api_ok GET "$query"
  entries="$(jq -c --argjson acc "$entries" '$acc + .items' "$BODY_FILE")"
  cursor="$(jq -r '.pageInfo.nextCursor // empty' "$BODY_FILE")"
  [[ -z "$cursor" ]] && break
  query="/api/catalog/entities/by-query?cursor=$(jq -rn --arg c "$cursor" '$c|@uri')&fields=$FIELDS"
done
entries="$(jq -c 'sort_by(.metadata.title // .metadata.name | ascii_downcase)' <<<"$entries")"
echo "Found $(jq length <<<"$entries") Marketplace entries."

# --- 3. Work out which entries are already installed ------------------------------------------
# Same rule as the Marketplace page: a completed marketplace task whose registered catalog
# entity (the `catalog` output link of the latest run) still exists in the catalog.
api_ok GET /api/scaffolder/marketplace/v1/tasks
task_refs="$(jq -c '[ .[]
  | (if (.data|type) == "string" then (.data|fromjson) else .data end) as $runs
  | { key: "\(.namespace)/\(.name)",
      ref: ([ $runs[0].output.links[]? | select(.type == "catalog" and .entityRef) | .entityRef ][0]) }
  | select(.ref != null) ]' "$BODY_FILE")"

installed='[]'
if [[ "$(jq length <<<"$task_refs")" -gt 0 ]]; then
  api_ok POST /api/catalog/entities/by-refs \
    "$(jq -c '{entityRefs: [.[].ref], fields: ["kind","metadata.name","metadata.namespace"]}' <<<"$task_refs")"
  existing="$(jq -c '[ .items[] | select(. != null)
    | "\(.kind)|\(.metadata.namespace)|\(.metadata.name)" | ascii_downcase ]' "$BODY_FILE")"
  installed="$(jq -c --argjson existing "$existing" '[ .[]
    | (.ref | ascii_downcase | capture("^(?<k>[^:]+):(?:(?<ns>[^/]+)/)?(?<n>.+)$")) as $r
    | select($existing | index("\($r.k)|\($r.ns // "default")|\($r.n)"))
    | .key ] | unique' <<<"$task_refs")"
fi

# --- 4. Decide what to install ------------------------------------------------------------------
plan="$(jq -c --argjson installed "$installed" '[ .[]
  | { name: .metadata.name,
      namespace: (.metadata.namespace // "default"),
      title: (.metadata.title // .metadata.name),
      multi: (.metadata["tibco.developer.hub/marketplace"].isMultiInstall == true) }
  | "\(.namespace)/\(.name)" as $key
  | .action = (if .multi then "skip-multi"
               elif ($installed | index($key)) then "skip-installed"
               else "install" end) ]' <<<"$entries")"

echo
echo "Skipping multi-install entries:"
jq -r '.[] | select(.action == "skip-multi") | "  - \(.title) (\(.name))"' <<<"$plan"
echo "Skipping already installed entries:"
jq -r '.[] | select(.action == "skip-installed") | "  - \(.title) (\(.name))"' <<<"$plan"

to_install="$(jq -c '[ .[] | select(.action == "install") ]' <<<"$plan")"
total="$(jq length <<<"$to_install")"
echo "Entries to install: $total"
jq -r '.[] | "  - \(.title) (\(.name))"' <<<"$to_install"

if [[ "$total" -eq 0 ]]; then
  echo "Nothing to install."
  exit 0
fi
if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1, not installing anything."
  exit 0
fi

# --- 5. Install -----------------------------------------------------------------------------------
echo
ok=0
failed=0
failed_names=()
i=0
while IFS=$'\t' read -r namespace name title; do
  i=$((i + 1))
  printf '[%d/%d] %s (%s) ... ' "$i" "$total" "$title" "$name"

  payload="$(jq -cn --arg ref "template:$namespace/$name" '{templateRef: $ref, values: {accept: true}}')"
  code="$(api POST /api/scaffolder/v2/tasks "$payload")"
  task_id="$(jq -r '.id // empty' "$BODY_FILE" 2>/dev/null || true)"
  if [[ "$code" != 201 || -z "$task_id" ]]; then
    echo "FAILED to start (HTTP $code): $(head -c 300 "$BODY_FILE")"
    failed=$((failed + 1)); failed_names+=("$name")
    continue
  fi

  status="open"
  deadline=$((SECONDS + TASK_TIMEOUT))
  while [[ "$status" == "open" || "$status" == "processing" ]]; do
    if (( SECONDS >= deadline )); then status="timeout"; break; fi
    sleep 2
    if [[ "$(api GET "/api/scaffolder/v2/tasks/$task_id")" == 200 ]]; then
      status="$(jq -r '.status // "unknown"' "$BODY_FILE")"
    fi
  done

  if [[ "$status" == "completed" ]]; then
    echo "installed"
    ok=$((ok + 1))
  else
    reason=""
    if [[ "$status" != "timeout" && "$(api GET "/api/scaffolder/v2/tasks/$task_id/events")" == 200 ]]; then
      reason="$(jq -r '[ .[] | .body.error.message // .body.message // empty ] | last // ""' "$BODY_FILE")"
    fi
    echo "FAILED ($status) ${reason:+- $reason}"
    echo "        task: $DEV_HUB_URL/create/tasks/$task_id"
    failed=$((failed + 1)); failed_names+=("$name")
  fi
done < <(jq -r '.[] | [.namespace, .name, .title] | @tsv' <<<"$to_install")

echo
echo "Done: $ok installed, $failed failed (of $total)."
if [[ "$failed" -gt 0 ]]; then
  printf '  failed: %s\n' "${failed_names[@]}"
  exit 1
fi
