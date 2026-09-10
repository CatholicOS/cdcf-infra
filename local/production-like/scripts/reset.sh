#!/usr/bin/env bash
set -euo pipefail

readonly script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir/.."

echo '[reset] Removing only cdcf-integration containers, networks, and named volumes.'
docker compose down --volumes --remove-orphans
echo '[reset] Complete. The next compose up will perform a real first boot.'
