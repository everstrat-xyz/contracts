#!/bin/bash

# GitHub-compatible forge fmt check script
# This script checks formatting using the same configuration as GitHub Actions CI

set -e

echo "Checking code formatting with GitHub CI configuration..."

# Use the CI profile to match GitHub Actions
FOUNDRY_PROFILE=ci forge fmt --check src/ test/

echo "✅ Code formatting is correct!"
