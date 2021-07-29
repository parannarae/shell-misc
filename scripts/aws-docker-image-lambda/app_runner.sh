#! /bin/bash

INFO_LOG="printf %s\n"
ENV_FILE_NAME='.env'
TEST_CONTAINER_SERVICE_NAME='sut'

# load from environment variable
CURRENT_ENV_PROFILE="${ENV_PROFILE}"
AWS_DEPLOY_REGION="${AWS_REGION}"
AWS_DEPLOY_ACCOUNT_ID="${AWS_ACCOUNT_ID}"

# create AWS related global variables
AWS_ECR_NAME='api-gw-lambda-auth'
AWS_IMAGE_URI="${AWS_DEPLOY_ACCOUNT_ID}.dkr.ecr.${AWS_DEPLOY_REGION}.amazonaws.com/${AWS_ECR_NAME}"
AWS_LAMBDA_FUNCTION_NAME="api-gateway-oauth-authorizer-${CURRENT_ENV_PROFILE}-function"
# temporary authenticator
AWS_LAMBDA_APP_ID_ONLY_FUNCTION_NAME="api-gateway-app-id-only-authorizer-${CURRENT_ENV_PROFILE}-function"


get_env_vairables() {
    # load `.env`
    if [[ -f "${ENV_FILE_NAME}" ]]; then
        # load all key value pairs
        set -a
        source "${ENV_FILE_NAME}"
        set +a
    else
        $INFO_LOG "${ENV_FILE_NAME} file does not exists"
        exit 1
    fi

    # check if environment variable exists
    if [[ -z "${ACCESS_TOKEN_PUBLIC_KEY}" ]]; then
        $INFO_LOG "Public key does not exists."
        exit 1
    fi
}

exit_when_process_failed() {
    local exit_code=$1
    local message
    message=$2

    if [[ "${exit_code}" -ne 0 ]]; then
        $INFO_LOG "${message}"
        exit "${exit_code}"
    fi
}


start_service() {
    get_env_vairables
    # GitHub Action does not support `docker compose` cli
    docker-compose up -d --build
    exit_code=$?
    exit_when_process_failed "${exit_code}" "docker compose has failed on starting services"
}


stop_service() {
    # GitHub Action does not support `docker compose` cli
    docker-compose stop
    exit_code=$?
    exit_when_process_failed "${exit_code}" "docker compose has failed on stopping services"
}


down_service() {
    # GitHub Action does not support `docker compose` cli
    docker-compose down
    exit_code=$?
    exit_when_process_failed "${exit_code}" "docker compose has failed on removing services"
}


test_service() {
    get_env_vairables

    # run test docker
    local exit_code
    # GitHub Action does not support `docker compose` cli
    docker-compose -f docker-compose.test.yml up --build --exit-code-from "${TEST_CONTAINER_SERVICE_NAME}"

    exit_code=$?
    exit_when_process_failed "${exit_code}" "Unittest has failed"
}


validate_publish_variables() {
    if [[ -z "${AWS_DEPLOY_REGION}" ]]; then
        $INFO_LOG "AWS region is not set."
        exit 1
    fi

    if [[ -z "${AWS_DEPLOY_ACCOUNT_ID}" ]]; then
        $INFO_LOG "AWS account id is not set."
        exit 1
    fi
}


get_ecr_credential() {
    local exit_code

    local ecr_password
    ecr_password="${AWS_DEPLOY_ACCOUNT_ID}.dkr.ecr.${AWS_DEPLOY_REGION}.amazonaws.com"
    # get credential for private repository
    aws ecr get-login-password --region "${AWS_DEPLOY_REGION}" \
        | docker login --username AWS --password-stdin "${ecr_password}"

    exit_code=$?
    exit_when_process_failed "${exit_code}" "Fail on getting the ECR credential"
}


# docker image name in registry
IMAGE_NAME=''


set_image_name_with_tag() {
    # set image name globally to use in other functions
    local image_tag=$1

    # set `IMAGE_NAME`
    IMAGE_NAME="${AWS_IMAGE_URI}:${image_tag}"
}


build_image() {
    # build image
    local temp_image_name="${AWS_ECR_NAME}:latest"
    docker build -t "${temp_image_name}" .

    # get tag from image metadata
    local image_tag
    image_tag=$(docker inspect --format '{{ .Config.Labels.version }}' "${temp_image_name}")

    # set tag image to publish
    set_image_name_with_tag "${image_tag}"
    docker tag "${temp_image_name}" "${IMAGE_NAME}"
}


validate_image_name() {
    # check if `IMAGE_NAME` is properly set
    if [[ -z "${IMAGE_NAME}" ]]; then
        $INFO_LOG "The image name is empty"
        exit 1
    fi
}


publish_docker_image() {
    validate_publish_variables

    # get ECR credential
    get_ecr_credential

    # build image
    $INFO_LOG "Start building an image..."
    build_image

    validate_image_name

    # publish
    local exit_code
    $INFO_LOG "Pushing the image..."
    docker push "${IMAGE_NAME}"

    exit_code=$?
    exit_when_process_failed "${exit_code}" "Fail on publishing an image"
}


set_image_name_to_ecr_latest() {
    # set global `IMAGE_NAME` variable to the latest published image in ECR
    local latest_tag
    # get latest tag from ecr
    #   note that aws cli uses JMESPath for the json query
    latest_tag=$(aws ecr describe-images \
        --repository-name ${AWS_ECR_NAME} \
        --query 'reverse(sort_by(imageDetails,& imagePushedAt)[*])[0].imageTags[0]' \
        --output text)

    $INFO_LOG "The latest image tag in ECR is ${latest_tag}"

    set_image_name_with_tag "${latest_tag}"
}


deploy_docker_image_to_lambda() {
    local function_name=$1

    # deploy the image to lambda
    local update_result
    update_result=$(aws lambda update-function-code --function-name "${function_name}" \
        --image-uri "${IMAGE_NAME}" \
        | jq '.State')

    # check the deployment result
    if [[ -z "${update_result}" ]] || [[ "${update_result}" == 'Failed' ]]; then
        $INFO_LOG "Lambda update has failed"
        exit 1
    fi
}


deploy_lambdas_with_latest_image() {
    set_image_name_to_ecr_latest
    validate_image_name

    local function_name
    function_name="arn:aws:lambda:${AWS_DEPLOY_REGION}:${AWS_DEPLOY_ACCOUNT_ID}:function:${AWS_LAMBDA_FUNCTION_NAME}"

    $INFO_LOG "Deploying ${AWS_LAMBDA_FUNCTION_NAME}..."
    deploy_docker_image_to_lambda "${function_name}"

    # temporary? (only checks cw-app-id)
    local app_id_only_function_name
    app_id_only_function_name="arn:aws:lambda:${AWS_DEPLOY_REGION}:${AWS_DEPLOY_ACCOUNT_ID}:function:${AWS_LAMBDA_APP_ID_ONLY_FUNCTION_NAME}"

    $INFO_LOG "Deploying ${AWS_LAMBDA_APP_ID_ONLY_FUNCTION_NAME}..."
    deploy_docker_image_to_lambda "${app_id_only_function_name}"

    $INFO_LOG "Finished deployment"
}


main() {
    case $1 in
    start)
        start_service
        ;;
    stop)
        stop_service
        ;;
    down)
        down_service
        ;;
    restart)
        stop_service
        start_service
        ;;
    test)
        test_service
        ;;
    publish)
        publish_docker_image
        ;;
    deploy)
        deploy_lambdas_with_latest_image
        ;;
    esac
}

main "$@"
