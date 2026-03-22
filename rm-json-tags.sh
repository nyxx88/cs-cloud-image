#!/bin/bash
: <<'#DESCRIPTION#'

File: rm_json_tags.sh

Description: Bash script to remove specific tags from a Fargate task definition JSON file.

Accepts the input JSON filename & sends the output to stdout, which can then be redirected to a file.


#DESCRIPTION#

#######################################################################################################################
# Script logic flow:
# - Loop through
#######################################################################################################################

err() {
    echo "Error: $*" >&2
    exit 1
}

if [ ! -f $1 ]; then
  err "File $1 was not found"
fi

# Read the content of the input file
task_defn=$(cat $1)


# Build the key filter for jq. This is to handle some esoteric situations. Read the following for details:
# - https://github.com/jqlang/jq/issues/1124
# - http://mywiki.wooledge.org/BashFAQ/050
unwanted_keys=("compatibilities" "registeredAt" "registeredBy" "requiresAttributes" "revision" "status" "taskDefinitionArn")

jq_filter="."

for key in ${unwanted_keys[@]}; do
  jq_filter+=" | del(.${key})"
done

# Check condition if the key "tags" is empty. If yes, add it to the filter. Currently, this logic is hard-coded.
if [ $(echo ${task_defn} | jq -r '.tags') == "[]" ]; then
  jq_filter+=" | del(.tags)"
  echo $jq_filter
fi

# Build the command to execute jq with all the parameters
jq_cmd=(jq "${jq_filter}")

echo ${task_defn} | "${jq_cmd[@]}"
