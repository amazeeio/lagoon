#!/usr/bin/env bash

set -euo pipefail

PAYLOAD='{
  "role": "admin",
  "iss": "auto-idler",
  "aud": "'$JWTAUDIENCE'",
  "sub": "auto-idler"
}'

jwtgen -a HS256 -s "${JWTSECRET}" --claims "${PAYLOAD}" $@