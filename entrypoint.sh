#!/bin/sh -l

set -ex

if [ -n "$INPUT_PATH" ]; then
  # Allow user to change directories in which to run Fly commands.
  cd "$INPUT_PATH" || exit
fi

PR_NUMBER=$(jq -r .number /github/workflow/event.json)
if [ -z "$PR_NUMBER" ]; then
  echo "This action only supports pull_request actions."
  exit 1
fi

REPO_NAME=$(jq -r .repository.name /github/workflow/event.json)
EVENT_TYPE=$(jq -r .action /github/workflow/event.json)

# Default the Fly app name to {repo_name}-pr-{pr_number}
app="${INPUT_NAME:-$REPO_NAME-pr-$PR_NUMBER}"
# # Default the Fly app name to {repo_name}-pr-{pr_number}-postgres
postgres_app="${INPUT_POSTGRES:-$REPO_NAME-pr-$PR_NUMBER-postgres}"
region="${INPUT_REGION:-${FLY_REGION:-ord}}"
org="${INPUT_ORG:-${FLY_ORG:-personal}}"
image="$INPUT_IMAGE"
memory="$INPUT_MEMORY"

if ! echo "$app" | grep "$PR_NUMBER"; then
  echo "For safety, this action requires the app's name to contain the PR number."
  exit 1
fi

# If PR is closed or merged, the app and its associated DB will be deleted
if [ "$EVENT_TYPE" = "closed" ]; then
  flyctl apps destroy "$app" -y || true
  if [ -n "$INPUT_POSTGRES" ]; then
    flyctl apps destroy "$postgres_app" -y || true
  fi

  message="Review app deleted." 
  echo "::set-output name=message::$message"
  exit 0
fi

# Create postgres app if it does not already exist
if [ -n "$INPUT_POSTGRES" ]; then
  if ! flyctl status --app "$postgres_app"; then
    flyctl postgres create --name "$postgres_app" --region "$region" --organization "$org" --vm-size shared-cpu-1x --volume-size 1 --initial-cluster-size 1 || true
  fi
fi

# Deploy the Fly app, creating it first if needed.
if ! flyctl status --app "$app"; then
  flyctl launch --no-deploy --copy-config --name "$app" --image "$image" --region "$region" --org "$org"
  if [ -n "$INPUT_SECRETS" ]; then
    echo $INPUT_SECRETS | tr " " "\n" | flyctl secrets import --app "$app"
  fi
  flyctl postgres attach --app "$app" --postgres-app "$postgres_app"
  # Using detach so the github action does not monitor deployment the whole time
  flyctl deploy --detach --app "$app" --region "$region" --image "$image" --region "$region" --strategy immediate
  statusmessage="Review app created. It may take a few minutes for the app to deploy."
elif [ "$EVENT_TYPE" = "synchronize" ]; then
  flyctl deploy --detach --app "$app" --region "$region" --image "$image" --region "$region" --strategy immediate
  statusmessage="Review app updated. It may take a few minutes for your changes to be deployed."
fi

if [ -n "$INPUT_MEMORY" ]; then
  flyctl scale memory "$memory" --app "$app"
fi

# Make some info available to the GitHub workflow.
fly status --app "$app" --json >status.json
hostname=$(jq -r .Hostname status.json)
appid=$(jq -r .ID status.json)
echo "::set-output name=hostname::$hostname"
echo "::set-output name=url::https://$hostname"
echo "::set-output name=id::$appid"
echo "::set-output name=message::$statusmessage https://$hostname"
