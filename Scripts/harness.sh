#!/bin/bash
# Runs the wipe-path integration harness in all modes. Each creates a fake card
# (temp dir) full of EXIF-dated JPEGs + a local fake NAS, drives a REAL session,
# and asserts end-to-end integrity + the all-or-nothing wipe safety property.
set -euo pipefail
cd "$(dirname "$0")/.."
for mode in run chaos-nas chaos-unreadable chaos-crash chaos-wrongcard; do
  swift run offload-harness "$mode"
  echo
done
echo "All harness modes passed."
