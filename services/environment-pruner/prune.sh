#!/bin/bash

# set -e -o pipefail

# Create a JWT admin token to talk to the API.
API_ADMIN_JWT_TOKEN=$(./create_jwt.sh)
BEARER="Authorization: bearer $API_ADMIN_JWT_TOKEN"

CUTOFF="${CUTOFF:--90 days}"
CUTOFF_DATE="$(date +'%Y-%m-%d %H:%M:%S' --date "$CUTOFF")"

# Load all the projects.
GRAPHQL='query environments {
  environments:allProjects {
    name
    productionEnvironment
    openshift {
      consoleUrl
      token
      name
    }
    environments {
      openshiftProjectName
      name
      updated
    }
  }
}'

# Convert GraphQL file into single line (but with still \n existing), turn \n into \\n, esapee the Quotes
query=$(echo $GRAPHQL | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g' | awk -F'\n' '{if(NR == 1) {printf $0} else {printf "\\n"$0}}')
ALL_ENVIRONMENTS=$(curl -s -XPOST -H 'Content-Type: application/json' -H "$BEARER" api:3000/graphql -d "{\"query\": \"$query\"}")

echo "$ALL_ENVIRONMENTS" | jq -c '.data.environments[] | select((.environments|length)>=1)' | while read project
  do
    PROJECT_NAME=$(echo "$project" | jq -r '.name')
    OPENSHIFT_URL=$(echo "$project" | jq -r '.openshift.consoleUrl')
    PRODUCTION_BRANCH=$(echo "$project" | jq -r '.productionEnvironment')

    echo "$project" | jq -c '.environments[]' | while read environment
    do
      ENVIRONMENT_OPENSHIFT_PROJECTNAME=$(echo "$environment" | jq -r '.openshiftProjectName')
      ENVIRONMENT_NAME=$(echo "$environment" | jq -r '.name')
      UPDATED_DATE=$(echo "$environment" | jq -r '.updated')

      echo "$OPENSHIFT_URL - $PROJECT_NAME: handling environment $ENVIRONMENT_NAME"

      if [[ "$ENVIRONMENT_NAME" == "$PRODUCTION_BRANCH" ]]; then
        # This should only ever remove non-prods.
        echo "$PROJECT_NAME: $ENVIRONMENT_NAME is the production environment"
        continue;
      fi

      # Skip if no openshift project exists.
      if ! oc --insecure-skip-tls-verify --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_URL" get project "$ENVIRONMENT_OPENSHIFT_PROJECTNAME" > /dev/null; then
        echo "$OPENSHIFT_URL - $PROJECT_NAME: $ENVIRONMENT_NAME: OpenShift Project not found"
        continue;
      fi

      # The updated date of the environment is newer than the expected cutoff.
      if [[ $UPDATED_DATE > $CUTOFF_DATE ]]; then
        continue;
      fi

      # Use Lagoon to delete the environment.
      GQL_MUTATION='mutation DelEnv($name !String $env !String) {
        deleteEnvironment(input: {
          name: $name
          project: $env
          execute: true
        })
      }'
      mutation=$(echo $GQL_MUTATION | sed 's/"/\\"/g' | sed 's/\\n/\\\\n/g' | awk -F'\n' '{if(NR == 1) {printf $0} else {printf "\\n"$0}}')
      DELETE=$(curl -s -XPOST -H 'Content-Type: application/json' -H "$BEARER" api:3000/graphql -d "{\"query\": \"$mutation\", \"variables\": {\"name\": \"$PROJECT_NAME\", \"env\": \"$ENVIRONMENT_NAME\"} }")
  done
done
