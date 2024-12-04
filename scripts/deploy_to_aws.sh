#!/bin/bash

# Script to deploy to AWS ECS using AWS CLI

# Variables
export AWS_REGION="eu-central-1"
export ECS_CLUSTER_NAME="deploy-aws-fastagency-cluster"
export ECR_NAME="deploy-aws-fastagency-repo"
export SERVICE_NAME="deploy-aws-fastagency-service"
export TASK_DEFINITION_NAME="deploy-aws-fastagency-task"
export VPC_NAME="deploy-aws-fastagency-vpc"
export SUBNET_NAME="deploy-aws-fastagency-subnet"

echo -e "\033[0;32mChecking if AWS CLI is configured\033[0m"
if ! aws sts get-caller-identity > /dev/null 2>&1; then
    echo -e "\033[0;32mAWS CLI is not configured. Please run 'aws configure' first.\033[0m"
    exit 1
else
    echo -e "\033[0;32mAWS CLI is configured.\033[0m"
fi

echo -e "\033[0;32mCreating ECR repository if it doesn't exist\033[0m"
if ! aws ecr describe-repositories --repository-names $ECR_NAME > /dev/null 2>&1; then
    aws ecr create-repository --repository-name $ECR_NAME
else
    echo -e "\033[0;32mECR repository already exists.\033[0m"
fi

ECR_URI=$(aws ecr describe-repositories --repository-names $ECR_NAME --query "repositories[0].repositoryUri" --output text)

echo -e "\033[0;32mBuilding and pushing Docker image to ECR\033[0m"
rm ~/.docker/config.json
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_URI
docker build -t $ECR_NAME -f docker/Dockerfile .
docker tag $ECR_NAME:latest $ECR_URI:latest
docker push $ECR_URI:latest

# echo -e "\033[0;32mSetting up VPC and Subnet if they don't exist\033[0m"
# if ! aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" > /dev/null 2>&1; then
#     VPC_ID=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query "Vpc.VpcId" --output text)
#     aws ec2 create-tags --resources $VPC_ID --tags Key=Name,Value=$VPC_NAME
# else
#     VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[0].VpcId" --output text)
# fi

# if ! aws ec2 describe-subnets --filters "Name=tag:Name,Values=$SUBNET_NAME" > /dev/null 2>&1; then
#     SUBNET_ID=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --query "Subnet.SubnetId" --output text)
#     aws ec2 create-tags --resources $SUBNET_ID --tags Key=Name,Value=$SUBNET_NAME
# else
#     SUBNET_ID=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=$SUBNET_NAME" --query "Subnets[0].SubnetId" --output text)
# fi

# echo -e "\033[0;32mCreating ECS cluster if it doesn't exist\033[0m"
# if ! aws ecs describe-clusters --clusters $ECS_CLUSTER_NAME > /dev/null 2>&1; then
#     aws ecs create-cluster --cluster-name $ECS_CLUSTER_NAME
# else
#     echo -e "\033[0;32mECS cluster already exists.\033[0m"
# fi

echo -e "\033[0;32mRegistering ECS task definition\033[0m"
TASK_DEFINITION=$(cat <<EOF
{
  "family": "$TASK_DEFINITION_NAME",
  "networkMode": "awsvpc",
  "containerDefinitions": [
    {
      "name": "$SERVICE_NAME",
      "image": "$ECR_URI:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 8888,
          "hostPort": 8888,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {
            "name": "OPENAI_API_KEY",
            "value": "$OPENAI_API_KEY"
        }
      ]
    }
  ],
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "1024",
  "memory": "2048"
}
EOF
)

echo "$TASK_DEFINITION" > task-definition.json
aws ecs register-task-definition --cli-input-json file://task-definition.json

echo -e "\033[0;32mCreating ECS service\033[0m"
if ! aws ecs describe-services --cluster $ECS_CLUSTER_NAME --services $SERVICE_NAME > /dev/null 2>&1; then
    aws ecs create-service \
        --cluster $ECS_CLUSTER_NAME \
        --service-name $SERVICE_NAME \
        --task-definition $TASK_DEFINITION_NAME \
        --desired-count 1 \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[subnet-12345678],securityGroups=[sg-12345678],assignPublicIp=ENABLED}"
        # --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],assignPublicIp=ENABLED}"
else
    echo -e "\033[0;32mECS service already exists.\033[0m"
fi

rm task-definition.json

echo -e "\033[0;32mYour ECS service is up and running!\033[0m"
