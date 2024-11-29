#!/usr/bin/env bash
set -e

echo "Running mypy..."
mypy

echo "Running bandit..."
bandit -c pyproject.toml -r deploy_azure_fastagency

echo "Running semgrep..."
semgrep scan --config auto --error
