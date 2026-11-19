#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

vendor=$(awk '$1 == "FROM" && $4 == "vendor" { print $2; exit }' Dockerfile.engine)
agent=ghcr.io/openappsec/agent@sha256:42d56e3d710bb874dfa8fe34dcb2ff90a0b27de03e3fe378b865d4baaf65cc1a
db=jc21/mariadb-aria@sha256:a5cfd4eacf2d13e049fc2263d61caa6ecafe95fc4147d24150ee3c024902005f
for tool in docker jq trivy; do command -v "$tool" >/dev/null; done
for ref in "$vendor" "$agent" "$db"; do
    [[ $ref =~ @sha256:[0-9a-f]{64}$ ]]
    docker image inspect "$ref" >/dev/null 2>&1 || docker pull --platform linux/amd64 "$ref"
done

work=$(mktemp -d)
tag="aegis-npm-check:${work##*.}"
cleanup() {
    docker image rm "$tag" >/dev/null 2>&1 || true
    rmdir -- "$work"
}
trap cleanup EXIT
docker buildx build --load --no-cache --platform linux/amd64 --target candidate -t "$tag" -f Dockerfile.engine .
id=$(docker image inspect --format '{{.Id}}' "$tag")
./test-modules.sh "$id"
./test-engine.sh "$id"
./smoke-test.sh "$id" "$agent" "$db" "$vendor"
./scan-images.sh "$vendor" "$id"
docker tag "$id" aegis-npm:security-candidate
printf 'Verified local candidate: aegis-npm:security-candidate (%s)\n' "$id"
