#!/bin/bash

# Send a GraphQL query to Lagoon API.
# Accpets query as first param. Usage:
# ALL_ENVIRONMENTS=$(./api-query.sh "query {
#   allProjects {
#     name
#   }
# }")

api_token=$(./create_jwt.py)
authz_header="Authorization: bearer $api_token"

# Convert GraphQL file into single line (but with still \n existing), turn \n into \\n, esapee the Quotes
query=$(echo $1 | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g' | awk -F'\n' '{if(NR == 1) {printf $0} else {printf "\\n"$0}}')
result=$(curl -s -XPOST -H 'Content-Type: application/json' -H "$authz_header" "${GRAPHQL_ENDPOINT:-api:3000/graphql}" -d "{\"query\": \"$query\"}")

echo "$result"
