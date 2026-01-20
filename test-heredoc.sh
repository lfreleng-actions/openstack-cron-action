#!/bin/bash
# Test heredoc with GitHub Actions variable format

cloud="vex
"
cat << TESTEOF
clouds:
  ${cloud}:
    test: value
TESTEOF
