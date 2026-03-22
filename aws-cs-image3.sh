#!/bin/bash
: <<'#DESCRIPTION#'

File: aws_cs_image2.sh

Description: Bash script to download any of the following from the CrowdStrike Container Registry
- Falcon Sensor for Linux (daemonset sensor) -- falcon-sensor
- Falcon Kubernetes Admission Controller (KAC) -- falcon-kac
- Falcon Image Analyzer (IAR) -- falcon-imagenanalyzer
- Falcon Container Sensor (sidecar) -- falcon-container

The following environment variables to be populated:
- FALCON_CLIENT_ID
- FALCON_CLIENT_SECRET

Other variables can be passed as parameters or environment variables:
- type of sensor to install
- type of container management on AWS
- whether to create an ECR to store your own copy of the sensor image
- level of debug


#DESCRIPTION#

#######################################################################################################################
# Script logic flow:
# - Get information about the account based on FALCON_CLIENT_ID & FALCON_CLIENT_SECRET:
#   - Authenticate using FALCON_CLIENT_ID & FALCON_CLIENT_SECRET to obtain:
#     - CrowdStrike Falcon API bearer token
#     - Information about which cloud the API client belongs to (this information is required to form the FQDN for
#       subsequent CrowdStrike Falcon API calls & image registry repository path formation)
#   - Retrieve the Falcon tenant's CID
# - Get information about the sensor
#   - Retrieve password to CrowdStrike registry
#   - Derive CrowdStrike registry username
#   - Authenticate against CrowdStrike registry to obtain bearer token to the registry
#   - With the registry bearer token, retrieve latest sensor tag
#   - Derive sensor image repository path
# - Generate image pull secret for CrowdStrike registry (will not be used if ECR is created)
# - If ECR creation is specified:
#   - Download sensor & push to own ECR repository
#     - Use docker to login to CrowdStrike registry
#     - Pull CrowdStrike sensor based on information retrieved earlier
#     - Create a new ECR
#     - Login to ECR
#     - Tag the sensor accordingly
#     - Push the sensor to the newly created ECR
#   - Generate image pull secret for ECR to be used in later steps
# - If container management is EKS:
#   - Generate environment preparation steps (e.g. create Kubernetes namespace, add Helm repository)
#   - If ECR created, generate Helm installation commandline to pull sensor from ECR
#   - Otherwise, generate Helm installation commmandline to pull sensor from CrowdStrike registry
# - If containter management is ECS (for now, the script assumes ECS management will be for Fargate):
#   - Prompt user for input in order to generate command to invoke the CrowdStrike patching utility
#   - If ECR created, generate commandline to invoke "patching tool" in sensor image hosted on ECR
#   - Otherwise, generate commandline to invoke "patching tool" in sensor image hosted on CrowdStrike registry
#######################################################################################################################

#######################################################################################################################
# Other notes:
# - Use the following command to check which registries your docker client is logged into
#   "jq -r '.auths | keys[]' ~/.docker/config.json"
#######################################################################################################################

# "Bash Strict Mode." This forces it to crash immediately when something goes wrong.
set -euo pipefail

# Script configuration
SCRIPT_NAME="$(basename "${0}")"                                                                   # SC2155 fix
readonly SCRIPT_NAME                                                                               # SC2155 fix

readonly ERR_LEVEL_1=1                                                                             # easy to fix problems (e.g. configuration values)
readonly ERR_LEVEL_2=2                                                                             # require more effort (e.g. wrong credentials, permissions related)
readonly ERR_LEVEL_3=3                                                                             # more sever (e.g. system problems beyond user)

readonly DEBUG_LEVEL_1=1
readonly DEBUG_LEVEL_2=2
readonly DEBUG_LEVEL_3=3
DEBUG="${DEBUG:-0}"                                                                                # default is "0" if it is not set

# ANSI color codes
readonly ANSI_RED="\033[0;31m"
readonly ANSI_YELLOW="\033[0;33m"
readonly ANSI_GREEN="\033[0;32m"
readonly ANSI_NOCOLOR="\033[0m"

readonly INSTRUCTION_COLOR="${ANSI_RED}"
readonly CLI_COLOR="${ANSI_GREEN}"
readonly HIGHLIGHT_COLOR="${ANSI_YELLOW}"

# CrowdStrike config
readonly FALCON_API_HOST_DEFAULT="api.crowdstrike.com"                                             # default Falcon API host, we need a starting point to make API calls
FALCON_API_HOST="${FALCON_API_HOST_DEFAULT}"
readonly CS_REGISTRY="registry.crowdstrike.com"
FALCON_CLIENT_ID="${FALCON_CLIENT_ID:-}"                                                           # default is "" if it is not set
FALCON_CLIENT_SECRET="${FALCON_CLIENT_SECRET:-}"                                                   # default is "" if it is not set

# AWS config
readonly AWS_CLI_EXIT_CODE_254=254
readonly ECR_REPO_NAME="falcon-images"
readonly AWS_IMAGE_TAG="latest"
AWS_ECR_REGION="${AWS_ECR_REGION:-}"                                                               # initialize it to an empty string if does not have value

# CrowdStrike Helm repo
readonly CS_HELM_REPO_URI="https://crowdstrike.github.io/falcon-helm"
readonly CS_HELM_REPO_NAME="crowdstrike"

# Arrays to keep various values for validation purposes
readonly VALID_IMAGE_TYPES=("falcon-sensor" "falcon-container" "falcon-kac" "falcon-imageanalyzer")
readonly VALID_AWS_CONTAINER_MGRS=("EKS" "ECS")
readonly VALID_CS_CLOUDS=("us-1" "us-2" "eu-1" "us-gov-1" "us-gov-2")
readonly REQUIRED_TOOLS=("aws" "base64" "curl" "docker" "jq")

# mapping of cloud to API host
declare -A cs_api_host
cs_api_host["us-1"]="api.crowdstrike.com"
cs_api_host["us-2"]="api.us-2.crowdstrike.com"
cs_api_host["eu-1"]="api.eu-1.crowdstrike.com"
cs_api_host["us-gov-1"]="api.laggar.gcw.crowdstrike.com"
cs_api_host["us-gov-2"]="api.us-gov-2.crowdstrike.com"

# For installation of Falcon Sensor for Linux (daemonset) using Helm
declare -A falcon_sensor_data
falcon_sensor_data["image_type"]="falcon-sensor"
falcon_sensor_data["release_name"]="falcon-sensor"
falcon_sensor_data["chart_name"]="${CS_HELM_REPO_NAME}/falcon-sensor"
falcon_sensor_data["k8s_namespace"]="falcon-system"

# falcon-kac for Helm
declare -A falcon_kac_data
falcon_kac_data["image_type"]="falcon-kac"
falcon_kac_data["release_name"]="falcon-kac"
falcon_kac_data["chart_name"]="${CS_HELM_REPO_NAME}/falcon-kac"
falcon_kac_data["k8s_namespace"]="falcon-kac"

# falcon-imageanalyzer for Helm
declare -A falcon_imageanalyzer_data
falcon_imageanalyzer_data["image_type"]="falcon-imageanalyzer"
falcon_imageanalyzer_data["release_name"]="falcon-imageanalyzer"
falcon_imageanalyzer_data["chart_name"]="${CS_HELM_REPO_NAME}/falcon-image-analyzer"
falcon_imageanalyzer_data["k8s_namespace"]="falcon-image-analyzer"

# Misc
readonly SUPPORT=1
readonly NO_SUPPORT=0
readonly FUTURE_SUPPORT=0

IMAGE_ENV="${IMAGE_ENV:-}"

# As and when new combination is supported/not supported, remember to update disp_image_env_support()
declare -A image_env_support
image_env_support["EKS:falcon-sensor"]="${SUPPORT}"
image_env_support["EKS:falcon-kac"]="${SUPPORT}"
image_env_support["EKS:falcon-imageanalyzer"]="${SUPPORT}"
image_env_support["EKS:falcon-container"]="${FUTURE_SUPPORT}"
image_env_support["ECS:falcon-sensor"]="${NO_SUPPORT}"
image_env_support["ECS:falcon-kac"]="${NO_SUPPORT}"
image_env_support["ECS:falcon-imageanalyzer"]="${NO_SUPPORT}"
image_env_support["ECS:falcon-container"]="${SUPPORT}"

#######################################################################################################################
# Script functions
#######################################################################################################################

disp_usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Required Flags:
    -u, --client-id <FALCON_CLIENT_ID>                Falcon API OAUTH Client ID (can be in \$FALCON_CLIENT_ID)
    -s, --client-secret <FALCON_CLIENT_SECRET>        Falcon API OAUTH Client Secret (can be in \$FALCON_CLIENT_SECRET)
    -t, --image-type <IMAGE_TYPE>                     Possible values: falcon-sensor, falcon-container (can be in \$IMAGE_TYPE)
    -c, --aws-container-mgr <AWS_CONTAINER_MGR>       AWS containter management, either EKS or ECS (can be in \$AWS_CONTAINER_MGR)

Optional Flags:
    -a, --aws-ecr-region <AWS_ECR_REGION>             AWS region in which to create ECR (can be in \$AWS_ECR_REGION)
    -d, --debug <DEBUG_LEVEL>                         Valid values are 1 or 2

Help Options:
    -h, --help                                        Display this help message"

EOF
   exit 2
}

disp_image_env_support() {
  cat <<EOF
Supported images and container environments:
- EKS:falcon-sensor
- EKS:falcon-kac
- EKS:falcon-imageanalyzer
- ECS:falcon-container

EOF
}

disp_err() {
  local err_level="${1}"
  local err_message="${*:2}"

  echo "Error: ${err_message}" >&2
  exit "${err_level}"
}

disp_debug() {
  local dbg_level="${1}"
  local dbg_source="${2}"
  local dbg_message="${*:3}"

  if [[ "${DEBUG}" -ge "${dbg_level}" ]]; then
    echo -e "[${dbg_level}:${dbg_source}] ${dbg_message}\n" >&2                                    # in case disp_debug() is accidentally called in functions that return values via stdin
  fi
}

parse_params() {
  while [[ $# != 0 ]]; do
    case $1 in
      -u | --client-id)
        if [[ -n "${2:-}" ]]; then
          FALCON_CLIENT_ID="${2}"
          shift
        fi
        ;;
      -s | --client-secret)
        if [[ -n "${2:-}" ]]; then
          FALCON_CLIENT_SECRET="${2}"
          shift
        fi
        ;;
      -t | --image-type)
        if [[ -n "${2:-}" ]]; then
          IMAGE_TYPE="$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
          shift
        fi
        ;;
      -c | --aws-container-mgr)
        if [[ -n "${2:-}" ]]; then
          AWS_CONTAINER_MGR="$(echo "${2}" | tr '[:lower:]' '[:upper:]')"
          shift
        fi
        ;;
      -a | --aws-ecr-region)
        if [[ -n "${2:-}" ]]; then
          AWS_ECR_REGION="$(echo "${2}" | tr '[:upper:]' '[:lower:]')"
          shift
        fi
        ;;
      -d | --debug)
        if [[ "${2:-}" =~ ^[0-2]$ ]]; then
          DEBUG="${2}"
          shift
        else
          disp_usage
        fi
        ;;
        -h | --help)
        if [[ -n "${1}" ]]; then
          disp_usage
        fi
        ;;
      --) # end argument parsing
        shift
        break
        ;;
      -*) # unsupported flags
        echo >&2 "Unsupported flag: ${1}"
        disp_usage
        ;;
    esac
    shift
  done
}

validate_value() {
  local value="${1}"                                                                               # value to be validated
  declare -n valid_value_list_ref="${2}"                                                           # nameref for the array
  declare -n valid_value_flag_ref="${3}"                                                           # nameref for the results flag

  valid_value_flag_ref=false                                                                       # initialize the flag before checking, in case parent function forgets

  for item in "${valid_value_list_ref[@]}"; do
    if [[ "${value}" == "${item}" ]]; then
      valid_value_flag_ref=true                                                                    # value used by calling function
      break
    fi
  done

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "value=${value}" "valid_item_list=" "${valid_value_list_ref[@]}"
}

validate_tools() {
  declare -n valid_tool_list_ref="${1}"                                                            # nameref for the array
  local missing_tools=()

  for tool in "${valid_tool_list_ref[@]}"; do
    if ! command -v "${tool}" &>/dev/null; then
        missing_tools+=("${tool}")
    fi
  done

  if [[ "${#missing_tools[@]}" -gt 0 ]]; then
    disp_err "${ERR_LEVEL_1}" "The following tools are missing -- [$(IFS=","; echo "${missing_tools[*]}")]"
  fi
}

# It first checks for the prescence of mandatory paramaters. Then it checks the validity of parameter values supplied to make sure those will be handled
# by the script, otherwise it will exit gracefully instead of exhibiting unpredictable behaviour.
validate_params() {
  local missing_params=()
  local is_valid=false
  local valid_aws_regions=()

  # Check for mandatory parameters
  # This is a concise way to check if a specific variable is empty. The ":-" portion is a 'safety' mechanism that assigns
  # an empty string if the variable is unset, so the script does not crash if nounset (set -u) is enabled
  [[ -z "${FALCON_CLIENT_ID:-}" ]] && missing_params+=("FALCON_CLIENT_ID")
  [[ -z "${FALCON_CLIENT_SECRET:-}" ]] && missing_params+=("FALCON_CLIENT_SECRET")
  [[ -z "${IMAGE_TYPE:-}" ]] && missing_params+=("IMAGE_TYPE")
  [[ -z "${AWS_CONTAINER_MGR:-}" ]] && missing_params+=("AWS_CONTAINER_MGR")

  # The array keeps a list of the missing parameters, but they are currently not used. However, if the script's
  # complexity grows in future, it could come in useful then.
  if [[ "${#missing_params[@]}" -gt 0 ]]; then
    disp_usage
  fi

  validate_value "${IMAGE_TYPE}" VALID_IMAGE_TYPES is_valid                                        # validate that IMAGE_TYPE parameter is supported
  if ! ${is_valid}; then
    # Inside the error message, ${VALID_IMAGE_TYPES[*]} (with the *) flattens the array into a single string. By setting
    # IFS=", ", we force Bash to put a comma between each item automatically.
    disp_err "${ERR_LEVEL_1}" "Image type \"${IMAGE_TYPE}\" is invalid. Valid values -- [$(IFS=","; echo "${VALID_IMAGE_TYPES[*]}")]"
  fi

  validate_value "${AWS_CONTAINER_MGR}" VALID_AWS_CONTAINER_MGRS is_valid                          # validate that AWS_CONTAINER_MGR is supported
  if ! ${is_valid}; then
    disp_err "${ERR_LEVEL_1}" "AWS container manager \"${AWS_CONTAINER_MGR}\" is invalid. Valid values -- [$(IFS=","; echo "${VALID_AWS_CONTAINER_MGRS[*]}")]"
  fi

  # Check if ECR creation was requested. If yes, validate if it is a valid region
  if [[ -n "${AWS_ECR_REGION}" ]]; then
    local valid_aws_regions

    # Get list of valid AWS regions and put it in an array
    read -ra valid_aws_regions < <(aws ec2 describe-regions --all-regions --query "Regions[].RegionName" --output text)
    disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "valid_aws_regions =" "${valid_aws_regions[@]}"

    validate_value "${AWS_ECR_REGION}" valid_aws_regions is_valid                                  # validate that AWS_ECR_REGION is supported
    if ! ${is_valid}; then
      disp_err "${ERR_LEVEL_1}" "AWS region \"${AWS_ECR_REGION}\" is invalid. Valid values -- [$(IFS=","; echo "${valid_aws_regions[*]}")]"
    fi
  fi
}

validate_sensor_env_support() {
  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "IMAGE_ENV=${IMAGE_ENV}"

  if (( ! "${image_env_support["${IMAGE_ENV}"]}" )); then
    disp_image_env_support
    disp_err "${ERR_LEVEL_1}" "The combination of the following image type and container environment is not supported -- ${IMAGE_ENV}"
  fi
}

get_falcon_api_bearer_token() {
  local tmp_file="${1}"
  local bearer_token="${bearer_token:-}"

  bearer_token="$(curl \
  --silent \
  --location \
  --request POST \
  --header "Content-Type: application/x-www-form-urlencoded" \
  --url "https://${FALCON_API_HOST}/oauth2/token" \
  --data "client_id=${FALCON_CLIENT_ID}&client_secret=${FALCON_CLIENT_SECRET}" \
  --dump-header "${tmp_file}" \
  | jq -r ".access_token")"

  if [[ -z "${bearer_token}" ]]; then
    disp_err "${ERR_LEVEL_2}" "Failed to obtain Falcon API bearer token. Please check credentials."
  else
    echo "${bearer_token}"
  fi
}

get_cs_cloud() {
  local tmp_file="${1}"
  local cloud="${cloud:-}"

  # Parse the stored header to get the value of "X-Cs-Region" to determine which CrowdStrike cloud the CID is on.
  # "grep" stops after first match, as there might be 2 sets of response headers. First being a 308 permanent
  # redirect from the wrong cloud, and the second being a 201 from the correct cloud. "xarg" trims the whitespaces,
  # "tr" deletes '\r' character
  cloud="$(grep -i x-cs-region -m 1 "${tmp_file}" | cut -d':' -f2 | xargs | tr -d '\r')"

  if [[ -z "${cloud}" ]]; then
    disp_err "${ERR_LEVEL_2}" "Failed to obtain Falcon cloud region from API HTTP response header."
  else
    echo "${cloud}"
  fi
}

set_falcon_api_host() {
  local cloud="${1}"
  local is_valid=false

  validate_value "${cloud}" VALID_CS_CLOUDS is_valid                                               # validate that cloud region is supported
  if ! ${is_valid}; then
    disp_err "${ERR_LEVEL_2}" "Unknown CrowdStrike cloud region: \"${cloud}\". Valid values -- [$(IFS=","; echo "${VALID_CS_CLOUDS[*]}")]"
  fi

  FALCON_API_HOST="${cs_api_host["${cloud}"]}"                                                     # use the value in ${cloud} to index into associative array to get API host
}

get_falcon_cid() {
  local api_bearer_token="${1}"
  local cid="${cid:-}"

  cid="$(curl \
  --silent \
  --request GET \
  --header "authorization: Bearer ${api_bearer_token}" \
  --url "https://${FALCON_API_HOST}/sensors/queries/installers/ccid/v1" \
  | jq -r ".resources[]")"

  if [[ -z "${cid}" ]]; then
    disp_err "${ERR_LEVEL_3}" "Failed to obtain Falcon CID."
  else
    echo "${cid}"
  fi
}

get_cs_reg_password() {
  local api_bearer_token="${1}"
  local reg_password="${reg_password:-}"

  reg_password="$(curl \
  --silent \
  --request GET \
  --header "authorization: Bearer ${api_bearer_token}" \
  --url "https://${FALCON_API_HOST}/container-security/entities/image-registry-credentials/v1" \
  | jq -r ".resources[].token")"

  if [[ -z "${reg_password}" ]]; then
    disp_err "${ERR_LEVEL_3}" "Failed to obtain Falcon registry password."
  else
    echo "${reg_password}"
  fi
}

get_cs_reg_bearer_token () {
  local reg_username="${1}"
  local reg_password="${2}"
  local reg_bearer_token="${reg_bearer_token:-}"

  reg_bearer_token="$(curl \
  --silent \
  --request GET \
  --user "${reg_username}:${reg_password}" \
  --url "https://${CS_REGISTRY}/v2/token?=${reg_username}" \
  | jq -r ".token")"

  if [[ -z "${reg_bearer_token}" ]]; then
    disp_err "${ERR_LEVEL_3}" "Failed to obtain Falcon registry bearer token."
  else
    echo "${reg_bearer_token}"
  fi
}

get_cs_image_list () {
  local reg_bearer_token="${1}"
  local image_list="${image_list:-}"

  image_list_url="https://${CS_REGISTRY}/v2/${IMAGE_TYPE}/release/${IMAGE_TYPE}/tags/list"                                                 # unified URL format

  image_list="$(curl \
  --silent \
  --request GET \
  --header "authorization: Bearer ${reg_bearer_token}" \
  --url "${image_list_url}")"

  if [[ -z "${image_list}" ]] || [[ "${image_list}" == "null" ]] || [[ "${image_list}" == *"errors"* ]]; then
    disp_debug "${DEBUG_LEVEL_3}" "${FUNCNAME[0]}:$LINENO" "image_list_url=${image_list}"
    if [[ -n "${image_list}" ]]; then
      disp_debug "${DEBUG_LEVEL_3}" "${FUNCNAME[0]}:$LINENO" "image_list=${image_list}"
    fi
    disp_err "${ERR_LEVEL_3}" "Failed to obtain Falcon image list."
  else
    echo "${image_list}"
  fi
}

get_cs_latest_sensor_tag() {
  local image_list="${1}"
  local tag="${tag:-}"

  tag="$(echo "${image_list}" | jq -r ".tags[]" | tail -1)"

  if [[ -z "${tag}" ]] || [[ "${tag}" == "null" ]]; then
    disp_err "${ERR_LEVEL_3}" "Failed to obtain latest sensor tag."
  else
    echo "${tag}"
  fi
}

get_cs_image_repo() {
  echo "${CS_REGISTRY}/${IMAGE_TYPE}/release/${IMAGE_TYPE}"
}

docker_login_cs_registry () {
  local reg_username="${1}"
  local reg_password="${2}"

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "docker login CS registry=${CS_REGISTRY}"

  # Docker login to ECR & check the exit code for failure
  if ! echo -n "${cs_reg_password}" | docker login --username "${cs_reg_username}" --password-stdin "${CS_REGISTRY}" > /dev/null 2>&1; then
    disp_err "${ERR_LEVEL_3}" "Failed to login to CrowdStrike registry."
  fi
}

docker_pull () {
  local image_repo="${1}"
  local image_tag="${2}"

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "docker pull ${image_repo}:${image_tag}"

  # Docker pull image & check the exit code for failure
  if ! docker pull "${image_repo}:${image_tag}" > /dev/null 2>&1; then
    disp_err "${ERR_LEVEL_3}" "Failed to pull image."
  fi
}

docker_push () {
  local image_repo="${1}"
  local image_tag="${2}"

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "docker push ${image_repo}:${image_tag}"

  # Docker push image & check the exit code for failure
  if ! docker push "${image_repo}:${image_tag}" > /dev/null 2>&1; then
    disp_err "${ERR_LEVEL_3}" "Failed to push image."
  fi
}

docker_tag () {
  local image_repo_1="${1}"
  local image_tag_1="${2}"
  local image_repo_2="${3}"
  local image_tag_2="${4}"

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" docker tag "${cs_image_repo}:${cs_image_tag}" "${aws_image_repo}:${AWS_IMAGE_TAG}"

  if ! docker tag "${image_repo_1}:${image_tag_1}" "${image_repo_2}:${image_tag_2}" > /dev/null 2>&1; then
    disp_err "${ERR_LEVEL_3}" "Failed to tag image."
  fi
}

get_aws_image_repo() {
  local image_repo
  local exit_code

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "AWS repo name=${ECR_REPO_NAME}/${IMAGE_TYPE}"

  # Check if repository exists before creation
  image_repo="$(aws ecr describe-repositories --repository-name "${ECR_REPO_NAME}/${IMAGE_TYPE}" --region "${AWS_ECR_REGION}" 2> /dev/null \
                | jq -r  '.repositories[].repositoryUri' | tail -1)"

  exit_code=$?
  # If ${image_repo} is an empty string & aws cli exit code is not 254, means some other error happened
  if [[ -z "${image_repo}" ]] && [[ "${exit_code}" -ne "${AWS_CLI_EXIT_CODE_254}" ]]; then
    disp_debug "${DEBUG_LEVEL_3}" "${FUNCNAME[0]}:$LINENO" "AWS repo name=${ECR_REPO_NAME}/${IMAGE_TYPE}" "Exit code :${exit_code}"
    disp_err "${ERR_LEVEL_3}" "Failed to obtain AWS image repository."
  else
    echo "${image_repo}"
  fi
}

create_aws_image_repo() {
  local image_repo

  image_repo=$(get_aws_image_repo)
  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "image_repo=${image_repo}"

  # If ${image_repo} is empty, means no ECR repo created
  if [[ -z "${image_repo}" ]]; then

    # Create ECR repo & check the exit code for failure
    if ! aws ecr create-repository --repository-name "${ECR_REPO_NAME}/${IMAGE_TYPE}" --region "${AWS_ECR_REGION}" > /dev/null 2>&1; then
      disp_debug "${DEBUG_LEVEL_3}" "${FUNCNAME[0]}:$LINENO" "AWS repo name=${ECR_REPO_NAME}/${IMAGE_TYPE}"
      disp_err "${ERR_LEVEL_3}" "Failed to create AWS image repository."
    fi

    # Get metadata of newly created repo
    image_repo=$(get_aws_image_repo)
  fi
  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "image_repo=${image_repo}"
  echo "${image_repo}"
}

docker_login_ecr() {
  local registry="${1}"

  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "AWS ECR registry=${registry}"

  # Docker login to ECR & check the exit code for failure
  if ! aws ecr get-login-password --region "${AWS_ECR_REGION}" | docker login --username AWS --password-stdin "${registry}" > /dev/null 2>&1; then
    disp_err "${ERR_LEVEL_3}" "Failed to login to AWS ECR registry."
  fi
}

gen_eks_falcon_sensor() {
  local registry
  local image_repo
  local image_tag
  local image_pull_secret

  # if ECR region is specified
  if [[ -n "${AWS_ECR_REGION}" ]]; then
    registry="AWS ECR"
    image_repo="${aws_image_repo}"
    image_tag="${AWS_IMAGE_TAG}"
    image_pull_secret="${aws_reg_image_pull_secret}"
  else
    registry="CrowdStrike registry"
    image_repo="${cs_image_repo}"
    image_tag="${cs_image_tag}"
    image_pull_secret="${cs_reg_image_pull_secret}"
  fi

  echo -e "\n${INSTRUCTION_COLOR}Run the following commands to install the falcon sensor using Helm:\n${CLI_COLOR}"

  cat <<EOF
# Create namespace and set pod security policy
kubectl create namespace ${falcon_sensor_data["k8s_namespace"]}
kubectl label namespace --overwrite ${falcon_sensor_data["k8s_namespace"]} pod-security.kubernetes.io/enforce=privileged

# Add CrowdStrike Helm repository
helm repo add ${CS_HELM_REPO_NAME} ${CS_HELM_REPO_URI}
helm repo update

# Using ${registry}
helm upgrade --install ${falcon_sensor_data["release_name"]} ${falcon_sensor_data["chart_name"]} \\
  -n ${falcon_sensor_data["k8s_namespace"]} \\
  --set falcon.cid=${falcon_cid} \\
  --set node.image.repository=${image_repo} \\
  --set node.image.tag=${image_tag} \\
  --set node.image.registryConfigJSON=${image_pull_secret}
EOF
  echo -e "${ANSI_NOCOLOR}"
}

gen_eks_falcon_kac() {
  local registry
  local image_repo
  local image_tag
  local image_pull_secret

  # if ECR region is specified
  if [[ -n "${AWS_ECR_REGION}" ]]; then
    registry="AWS ECR"
    image_repo="${aws_image_repo}"
    image_tag="${AWS_IMAGE_TAG}"
    image_pull_secret="${aws_reg_image_pull_secret}"
  else
    registry="CrowdStrike registry"
    image_repo="${cs_image_repo}"
    image_tag="${cs_image_tag}"
    image_pull_secret="${cs_reg_image_pull_secret}"
  fi

  echo -e "\n${INSTRUCTION_COLOR}Run the following commands to install the falcon sensor using Helm:\n${CLI_COLOR}"

  cat <<EOF
# Add CrowdStrike Helm repository
helm repo add ${CS_HELM_REPO_NAME} ${CS_HELM_REPO_URI}
helm repo update

# Using ${registry}
helm upgrade --install ${falcon_kac_data["release_name"]} ${falcon_kac_data["chart_name"]} --create-namespace \\
  -n ${falcon_kac_data["k8s_namespace"]} \\
  --set falcon.cid=${falcon_cid} \\
  --set image.repository=${image_repo} \\
  --set image.tag=${image_tag} \\
  --set image.registryConfigJSON=${image_pull_secret}
EOF
  echo -e "  --set clusterName=${HIGHLIGHT_COLOR}<cluster_name>${ANSI_NOCOLOR}\n"
}

gen_eks_falcon_imageanalyzer() {
  local registry
  local image_repo
  local image_tag
  local image_pull_secret

  # if ECR region is specified
  if [[ -n "${AWS_ECR_REGION}" ]]; then
    registry="AWS ECR"
    image_repo="${aws_image_repo}"
    image_tag="${AWS_IMAGE_TAG}"
    image_pull_secret="${aws_reg_image_pull_secret}"
  else
    registry="CrowdStrike registry"
    image_repo="${cs_image_repo}"
    image_tag="${cs_image_tag}"
    image_pull_secret="${cs_reg_image_pull_secret}"
  fi

  echo -e "\n${INSTRUCTION_COLOR}Run the following commands to install the falcon sensor using Helm:\n${CLI_COLOR}"

  cat <<EOF
# Create namespace and set pod security policy
kubectl create namespace ${falcon_imageanalyzer_data["k8s_namespace"]}
kubectl label namespace --overwrite ${falcon_imageanalyzer_data["k8s_namespace"]} pod-security.kubernetes.io/enforce=privileged

# Add CrowdStrike Helm repository
helm repo add ${CS_HELM_REPO_NAME} ${CS_HELM_REPO_URI}
helm repo update

# Using ${registry}
helm install ${falcon_imageanalyzer_data["release_name"]} ${falcon_imageanalyzer_data["chart_name"]} --create-namespace \\
  -n ${falcon_imageanalyzer_data["k8s_namespace"]} \\
  --set falcon.cid=${falcon_cid} \\
  --set image.repository=${image_repo} \\
  --set image.tag=${image_tag}
EOF
  echo -e "${ANSI_NOCOLOR}"
}

gen_ecr_falcon_container() {
  local registry
  local image_repo
  local image_tag
  local image_pull_secret

  local task_file_path
  local in_task_defintion_file
  local out_task_defintion_file

  # Prompt for user input
  echo -n "Please enter directory path where the task definition file can be located: "
  read -r task_file_path

  echo -n "Please enter the name of the source task definition file: "
  read -r in_task_defintion_file

  echo -n "Please enter the name of the destination task definition file: "
  read -r out_task_defintion_file

  # if ECR region is specified
  if [[ -n "${AWS_ECR_REGION}" ]]; then
    registry="AWS ECR"
    image_repo="${aws_image_repo}"
    image_tag="${AWS_IMAGE_TAG}"
    image_pull_secret="${aws_reg_image_pull_secret}"
  else
    registry="CrowdStrike registry"
    image_repo="${cs_image_repo}"
    image_tag="${cs_image_tag}"
    image_pull_secret="${cs_reg_image_pull_secret}"
  fi

  # Generate the command to execute in order to patch the task definition file
  echo -e "\n${INSTRUCTION_COLOR}Run the following commandline to patch the task definition file:\n${CLI_COLOR}"

  cat <<EOF
# Using ${registry}
docker run -v ${task_file_path}:/var/run/spec \\
  --rm ${image_repo}:${image_tag} \\
  -cid ${falcon_cid} \\
  -image ${image_repo}:${image_tag} \\
  -pulltoken ${image_pull_secret} \\
  -ecs-spec-file /var/run/spec/${in_task_defintion_file} > ${out_task_defintion_file}"
EOF
  echo -e "${ANSI_NOCOLOR}"
}

#######################################################################################################################
# Using a main() type of structure transforms a script from a 'list of commands' style to a more modular and maintainable
# form. Using main() has the following advantages:
# - Control the scope of variables so it local instead of global.
# - The main() function is called at the very end of a script, so if a downloaded script is interrupted, it is not
#   executed partially because main() that is at the end is never called -- avoiding a partial execution scenario.
#   Though, this is rare.
# - Improves understandability by others reading the code, who can grasp the main logic in main(), instead of going
#   through many lines of code before getting to the main logic.
#######################################################################################################################
main() {
  local tmp_file
  local falcon_api_bearer_token
  local cs_cloud
  local falcon_cid
  local cs_reg_password
  local cs_reg_username
  local cs_reg_bearer_token
  local cs_image_list
  local cs_image_tag
  local cs_image_repo
  local cs_reg_image_pull_secret

  local aws_registry
  local aws_image_repo
  local aws_reg_image_pull_secret

  # Using associative arrays to reduce the use of nested/convoluted if-else statements or case statements
  local -A image_env_gen
  image_env_gen["EKS:falcon-sensor"]=gen_eks_falcon_sensor
  image_env_gen["EKS:falcon-kac"]=gen_eks_falcon_kac
  image_env_gen["EKS:falcon-imageanalyzer"]=gen_eks_falcon_imageanalyzer
  image_env_gen["ECS:falcon-container"]=gen_ecr_falcon_container

  parse_params "$@"                                                                                # parse the CLI parameters
  validate_params                                                                                  # validate the input parameters

  # Build the string to identify the combination of image type and container environment
  IMAGE_ENV="${AWS_CONTAINER_MGR}:${IMAGE_TYPE}"
  validate_sensor_env_support

  # Validate that the minimal set of tools are present. If so desired a list of optional tools can be created and the function
  # be called again to validate against that list. Will leave this option open for others to explore & extend as required.
  validate_tools REQUIRED_TOOLS

  # Create a temporary file to store HTTP header in the following steps
  tmp_file="$(mktemp)"
  # shellcheck disable=SC2064                                                                      # purposely expanding the value early instead of at EXIT signal -- this is to overcome a convoluted problem of a local variable whose scope vanishes when the function ends, causing an "unbound variable" error.
  trap "rm '${tmp_file}'" EXIT                                                                     # delete ${tmp_file} when script exits

  # Get API bearer token, and store the return header in a temporary file
  falcon_api_bearer_token="$(get_falcon_api_bearer_token "${tmp_file}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "falcon_api_bearer_token=${falcon_api_bearer_token}"

  # Get CrowdStrike cloud region stored in the return header in a temporary file
  cs_cloud="$(get_cs_cloud "${tmp_file}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_cloud=${cs_cloud}"

  # Set the value of the Falcon API host based on the cloud region
  set_falcon_api_host "${cs_cloud}"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "FALCON_API_HOST=${FALCON_API_HOST}"

  # Get CID
  falcon_cid="$(get_falcon_cid "${falcon_api_bearer_token}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "falcon_cid=${falcon_cid}"

  # Get CrowdStrike registry password
  cs_reg_password="$(get_cs_reg_password "${falcon_api_bearer_token}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_reg_password=${cs_reg_password}"

  # Format username to login to registry. This is too simple to make into a function.
  cs_reg_username="fc-$(echo "$falcon_cid" | awk '{ print tolower($0) }' | cut -d'-' -f1)"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_reg_username=${cs_reg_username}"

  # Get CrowdStrike registry bearer token
  cs_reg_bearer_token="$(get_cs_reg_bearer_token "${cs_reg_username}" "${cs_reg_password}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_reg_bearer_token=${cs_reg_bearer_token}"

  # Get all available sensor image tags
  cs_image_list="$(get_cs_image_list "${cs_reg_bearer_token}")"
  disp_debug "${DEBUG_LEVEL_2}" "${FUNCNAME[0]}:$LINENO" "cs_image_list=${cs_image_list}"

  # Get the latest image tag
  cs_image_tag="$(get_cs_latest_sensor_tag "${cs_image_list}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_image_tag=${cs_image_tag}"

  # Get the CrowdStrike sensor repository string
  cs_image_repo="$(get_cs_image_repo "${cs_cloud}")"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_image_repo=${cs_image_repo}"

  # Construct the CrowdStrike registry image pull secret. Arguably this code can be made more readable, but I like the simplicity of this, so I am keeping this :)
  cs_reg_image_pull_secret="$(echo -n "{\"auths\":{\"${CS_REGISTRY}\":{\"auth\":\"$(echo -n "${cs_reg_username}:${cs_reg_password}" | base64 -w 0)\"}}}" | base64 -w 0)"
  disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "cs_reg_image_pull_secret=${cs_reg_image_pull_secret}"

  # if ECR region is specified
  if [[ -n "${AWS_ECR_REGION}" ]]; then
    # Docker to login to CrowdStrike registry
    docker_login_cs_registry "${cs_reg_username}" "${cs_reg_password}"

    # Pull sensor image from CrowdStrike registry
    docker_pull "${cs_image_repo}" "${cs_image_tag}"

    # Create ECR repo, and get the metadata
    aws_image_repo="$(create_aws_image_repo)"
    disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "aws_image_repo=${aws_image_repo}"

    # Get AWS registry
    aws_registry="$(echo "${aws_image_repo}" | cut -d'/' -f1)"
    disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "aws_registry=${aws_registry}"

    # Docker login to AWS ECR
    docker_login_ecr "${aws_registry}"

    # Tag the image to point to your registry
    docker_tag "${cs_image_repo}" "${cs_image_tag}" "${aws_image_repo}" "${AWS_IMAGE_TAG}"

    # Push image into ECR repo
    docker_push "${aws_image_repo}" "${AWS_IMAGE_TAG}"

    # Get pull token for the ECR registry. AWS ECR credentials are short-lived, so this must be refreshed periodically.
    aws_reg_image_pull_secret="$(echo -n "{\"auths\":{\"${aws_registry}\":{\"auth\":\"$(echo -n AWS:"$(aws ecr get-login-password --region "${AWS_ECR_REGION}")" | base64 -w 0)\"}}}" | base64 -w 0)"
    disp_debug "${DEBUG_LEVEL_1}" "${FUNCNAME[0]}:$LINENO" "aws_reg_image_pull_secret=${aws_reg_image_pull_secret}"
  fi

  "${image_env_gen[${IMAGE_ENV}]}"
}

#######################################################################################################################
# Check if main() is called directly. Run only if it is called directly & not imported as a library.
#######################################################################################################################
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
