#!/bin/bash
# Simulate the fix

cloud_name="vex
"
auth_url="https://example.com"

cat << TESTEOF
clouds:
  ${cloud_name}:
    auth:
      auth_url: ${auth_url}
TESTEOF
