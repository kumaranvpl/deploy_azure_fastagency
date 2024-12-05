#!/bin/bash

# AWS Configuration
AWS_REGION="eu-central-1"  # Replace with your region
CONTAINER_APP_NAME="deploy-aws-fastagency"
ECR_REPO_NAME="${CONTAINER_APP_NAME}"
APP_RUNNER_ROLE_NAME="AppRunnerECRAccessRole"
IAM_POLICY_NAME="PassRolePolicyForAppRunner"

echo -e "\033[0;32mChecking if AWS CLI is configured\033[0m"
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo -e "\033[0;32mAWS CLI is not configured. Please run 'aws configure' first.\033[0m"
    exit 1
else
    echo -e "\033[0;32mAWS CLI is configured.\033[0m"
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)

echo -e "\033[0;32mCreating IAM role for App Runner if it doesn't exist\033[0m"
if ! aws iam get-role --role-name $APP_RUNNER_ROLE_NAME --region $AWS_REGION > /dev/null 2>&1; then
    aws iam create-role \
        --region $AWS_REGION \
        --role-name $APP_RUNNER_ROLE_NAME \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Principal": {
                        "Service": "build.apprunner.amazonaws.com"
                    },
                    "Action": "sts:AssumeRole"
                }
            ]
        }' \
        --description "Role to allow AWS App Runner to pull images from ECR"
    echo -e "\033[0;32mIAM role $APP_RUNNER_ROLE_NAME created.\033[0m"
else
    echo -e "\033[0;32mIAM role $APP_RUNNER_ROLE_NAME already exists.\033[0m"
fi

echo -e "\033[0;32mAttaching ECR read-only policy to the IAM role\033[0m"
aws iam attach-role-policy \
    --region $AWS_REGION \
    --role-name $APP_RUNNER_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

echo -e "\033[0;32mCreating PassRolePolicy for App Runner if it doesn't exist\033[0m"
if ! aws iam get-policy --policy-arn arn:aws:iam::$ACCOUNT_ID:policy/$IAM_POLICY_NAME --region $AWS_REGION > /dev/null 2>&1; then
    aws iam create-policy \
        --region $AWS_REGION \
        --policy-name $IAM_POLICY_NAME \
        --policy-document '{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": "iam:PassRole",
                    "Resource": "arn:aws:iam::'"$ACCOUNT_ID"':role/'"$APP_RUNNER_ROLE_NAME"'"
                }
            ]
        }'
    echo -e "\033[0;32mPolicy $IAM_POLICY_NAME created.\033[0m"
else
    echo -e "\033[0;32mPolicy $IAM_POLICY_NAME already exists.\033[0m"
fi

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


echo -e "\033[0;32mDeploying to AWS App Runner\033[0m"
# Check if App Runner service exists
if ! aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$CONTAINER_APP_NAME']" --output text --region $AWS_REGION | grep -q .; then
    echo -e "\033[0;32mCreating new App Runner service\033[0m"
    SERVICE_ARN=$(aws apprunner create-service \
        --service-name $CONTAINER_APP_NAME \
        --region $AWS_REGION \
        --source-configuration '{
            "AuthenticationConfiguration": {
                "AccessRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/$APP_RUNNER_ROLE_NAME"
            },
            "ImageRepository": {
                "ImageIdentifier": "'$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest'",
                "ImageRepositoryType": "ECR",
                "ImageConfiguration": {
                    "Port": "8888",
                    "RuntimeEnvironmentVariables": {"OPENAI_API_KEY": "'$OPENAI_API_KEY'"}
                }
            }
        }' \
        --instance-configuration '{
            "Cpu": "1 vCPU",
            "Memory": "2 GB"
        }' \
        --query 'Service.ServiceArn' \
        --output text)
else
    echo -e "\033[0;32mUpdating existing App Runner service\033[0m"
    SERVICE_ARN=$(aws apprunner list-services --query "ServiceSummaryList[?ServiceName=='$CONTAINER_APP_NAME'].ServiceArn" --output text --region $AWS_REGION)
    aws apprunner update-service \
        --service-arn $SERVICE_ARN \
        --source-configuration '{
            "AuthenticationConfiguration": {
                "AccessRoleArn": "arn:aws:iam::$AWS_ACCOUNT_ID:role/$APP_RUNNER_ROLE_NAME"
            },
            "ImageRepository": {
                "ImageIdentifier": "'$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ECR_REPO_NAME:latest'",
                "ImageRepositoryType": "ECR",
                "ImageConfiguration": {
                    "Port": "8888",
                    "RuntimeEnvironmentVariables": {"OPENAI_API_KEY": "'$OPENAI_API_KEY'"}
                }
            }
        }' \
        --instance-configuration '{
            "Cpu": "1 vCPU",
            "Memory": "2 GB"
        }' \
        --query 'Service.ServiceArn' \
        --output text
fi


SERVICE_URL=$(aws apprunner describe-service --service-arn $SERVICE_ARN \
    --query 'Service.ServiceUrl' \
    --output text)

echo -e "\033[0;32mYour AWS App Runner service is deployed!\033[0m"
echo -e "\033[0;32mService URL: $SERVICE_URL\033[0m"
