#!/usr/bin/env bash
set -euo pipefail

baseline=${1:?Usage: security/scan-images.sh BASE_IMAGE CANDIDATE_IMAGE}
candidate=${2:?Pass the local candidate image}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
scan=(trivy image --image-src docker --scanners vuln --pkg-types os,library
      --severity HIGH,CRITICAL --ignorefile /dev/null --format json --no-progress)

for role in baseline candidate; do
    ref=$baseline
    if [[ $role == candidate ]]; then
        ref=$candidate
        scan+=(--skip-db-update)
    fi
    id=$(docker image inspect --format '{{.Id}}' "$ref")
    "${scan[@]}" -o "$work/report.json" "$id"
    jq -e --arg id "$id" '.Metadata.ImageID == $id and any(.Results[]; .Type == "debian")' \
        "$work/report.json" >/dev/null
    jq -r '.Results[] | .Type as $type | .Vulnerabilities[]? |
        [$type, .PkgName, .VulnerabilityID, .Severity] | @tsv' "$work/report.json" |
        LC_ALL=C sort -u > "$work/$role.tsv"
    printf '%s: %s unique HIGH/CRITICAL package findings\n' "$role" "$(wc -l < "$work/$role.tsv")"
done
LC_ALL=C comm -13 "$work/baseline.tsv" "$work/candidate.tsv" > "$work/new.tsv"
LC_ALL=C comm -23 "$work/baseline.tsv" "$work/candidate.tsv" > "$work/removed.tsv"
printf 'Removed findings: %s\nNew findings: %s\n' "$(wc -l < "$work/removed.tsv")" "$(wc -l < "$work/new.tsv")"
if [[ -s $work/new.tsv ]]; then
    cat "$work/new.tsv" >&2
    exit 1
fi
