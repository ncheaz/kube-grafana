#!/bin/bash

# MCP Grafana Server Container Runner
# This script runs the mcp/grafana container with proper port mapping

# Source environment variables from .env file
if [ -f .env ]; then
    source .env
fi

# Environment variables (use values from .env if available)
export GRAFANA_URL="${EXTERNAL_URL:-http://grafana.local}"
export GRAFANA_USERNAME="${GRAFANA_ADMIN_USER:-admin}"
export GRAFANA_PASSWORD="${GRAFANA_PASSWORD:-uiAyVbNOErdhtWlwIwHxOtEtcD7n2J9UF2JAKsKl}"

# Run the container with port mapping
# Port 3000 is mapped for Grafana web interface access
docker run --rm -i \
  -e GRAFANA_URL \
  -e GRAFANA_USERNAME \
  -e GRAFANA_PASSWORD \
  -p 8100:8000 \
  mcp/grafana \
  -t stdio
