#!/bin/bash

# AWS Configuration
AWS_REGION="eu-central-1"  # Replace with your region
CONTAINER_APP_NAME="deploy-aws-fastagency"
ECR_REPO_NAME="${CONTAINER_APP_NAME}"

echo -e "\033[0;32mChecking if AWS CLI is configured\033[0m"
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo -e "\033[0;32mAWS CLI is not configured. Please run 'aws configure' first.\033[0m"
    exit 1
else
    echo -e "\033[0;32mAWS CLI is configured.\033[0m"
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

echo -e "\033[0;32mAuthenticating with AWS ECR\033[0m"
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Create ECR repository if it doesn't exist
if ! aws ecr describe-repositories --repository-names $ECR_REPO_NAME --region $AWS_REGION > /dev/null 2>&1; then
    echo -e "\033[0;32mCreating ECR repository\033[0m"
    aws ecr create-repository --repository-name $ECR_REPO_NAME --region $AWS_REGION
fi

echo -e "\033[0;32mBuilding and pushing docker image to ECR\033[0m"
docker build -t $ECR_REPO_NAME:latest -f docker/Dockerfile .
docker tag $ECR_REPO_NAME:latest $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest

# # Create the role trust policy file
# cat > trust-policy.json << EOF
# {
#   "Version": "2012-10-17",
#   "Statement": [
#     {
#       "Effect": "Allow",
#       "Principal": {
#         "Service": "build.apprunner.amazonaws.com"
#       },
#       "Action": "sts:AssumeRole"
#     }
#   ]
# }
# EOF

# # Create the role
# ROLE_NAME="AppRunnerECRAccessRole"
# aws iam create-role \
#   --role-name $ROLE_NAME \
#   --assume-role-policy-document file://trust-policy.json \
#   --region $AWS_REGION

# # Attach ECR access policy
# aws iam attach-role-policy \
#   --role-name $ROLE_NAME \
#   --policy-arn arn:aws:iam::aws:policy/service-role/AWSAppRunnerServicePolicyForECRAccess \
#     --region $AWS_REGION

# # Get and export the role ARN
# export AWS_APP_RUNNER_ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query Role.Arn --output text --region $AWS_REGION)

echo -e "\033[0;32mDeploying to AWS App Runner\033[0m"
# Check if App Runner service exists
if ! aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$CONTAINER_APP_NAME']" --output text --region $AWS_REGION | grep -q .; then
    echo -e "\033[0;32mCreating new App Runner service\033[0m"
    aws apprunner create-service \
        --service-name $CONTAINER_APP_NAME \
        --region $AWS_REGION \
        --source-configuration "{
            \"AuthenticationConfiguration\": {
                \"AccessRoleArn\": \"$AWS_APP_RUNNER_ROLE_ARN\"
            },
            \"AutoDeploymentsEnabled\": true,
            \"ImageRepository\": {
                \"ImageIdentifier\": \"$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest\",
                \"ImageRepositoryType\": \"ECR\"
            }
        }" \
        --instance-configuration "{
            \"Cpu\": \"1024\",
            \"Memory\": \"2048\"
        }"
else
    echo -e "\033[0;32mUpdating existing App Runner service\033[0m"
    SERVICE_ARN=$(aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$CONTAINER_APP_NAME'].ServiceArn" --output text --region $AWS_REGION)
    aws apprunner update-service \
        --service-arn $SERVICE_ARN \
        --region $AWS_REGION \
        --source-configuration "{
            \"AuthenticationConfiguration\": {
                \"AccessRoleArn\": \"$AWS_APP_RUNNER_ROLE_ARN\"
            },
            \"AutoDeploymentsEnabled\": true,
            \"ImageRepository\": {
                \"ImageIdentifier\": \"$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest\",
                \"ImageRepositoryType\": \"ECR\"
            }
        }"
fi