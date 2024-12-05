#!/bin/bash

# Script to deploy to AWS ECS using AWS CLI

# Variables
export AWS_REGION=${NATS_FASTAPI_PORT:-"eu-central-1"}
export ECS_CLUSTER_NAME="deploy-aws-fastagency-cluster"
export ECR_NAME="deploy-aws-fastagency-repo"
export SERVICE_NAME="deploy-aws-fastagency-service"
export TASK_DEFINITION_NAME="deploy-aws-fastagency-task"
export VPC_NAME="deploy-aws-fastagency-vpc"
export SUBNET_NAME="deploy-aws-fastagency-subnet"
export DESIRED_COUNT=1

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


echo -e "\033[0;32mCreating ECS cluster if it doesn't exist\033[0m"
CLUSTER_CHECK=$(aws ecs describe-clusters \
    --clusters "$ECS_CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'clusters[0].clusterName' \
    --output text 2>/dev/null)

# Conditional check for cluster existence
if [ "$CLUSTER_CHECK" == "$ECS_CLUSTER_NAME" ]; then
    echo -e "\033[0;32mECS cluster already exists.\033[0m"
else
    # Create the ECS cluster
    aws ecs create-cluster \
        --cluster-name "$ECS_CLUSTER_NAME" \
        --region "$AWS_REGION"
fi

echo -e "\033[0;32mFetching account id\033[0m"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo -e "\033[0;32mRegistering ECS task definition\033[0m"
TASK_DEFINITION=$(cat <<EOF
{
  "family": "$TASK_DEFINITION_NAME",
  "networkMode": "awsvpc",
  "executionRoleArn": "arn:aws:iam::$ACCOUNT_ID:role/ecsTaskExecutionRole",
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

echo -e "\033[0;32mCreating VPC\033[0m"
VPC_CHECK=$(aws ec2 describe-vpcs \
    --filters "Name=tag:Name,Values=$VPC_NAME" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null)

# Conditional check for VPC existence
if [ -z "$VPC_CHECK" ]; then
    # Create the VPC
    VPC_ID=$(aws ec2 create-vpc \
        --cidr-block 10.0.0.0/16 \
        --query 'Vpc.VpcId' \
        --output text)

    # Add a name tag to the VPC
    aws ec2 create-tags \
        --resources "$VPC_ID" \
        --tags "Key=Name,Value=$VPC_NAME"

    # Enable DNS support and DNS hostnames in the VPC
    aws ec2 modify-vpc-attribute \
        --vpc-id "$VPC_ID" \
        --enable-dns-support "{\"Value\":true}"

    aws ec2 modify-vpc-attribute \
        --vpc-id "$VPC_ID" \
        --enable-dns-hostnames "{\"Value\":true}"
else
    echo -e "\033[0;32mVPC already exists.\033[0m"
    VPC_ID=$VPC_CHECK
fi

echo -e "\033[0;32mCreating subnet\033[0m"
SUBNET_CHECK=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'Subnets[0].SubnetId' \
    --output text 2>/dev/null)

# Conditional check for subnet existence
if [ -z "$SUBNET_CHECK" ]; then
    # Create the subnet
    SUBNET_ID=$(aws ec2 create-subnet \
        --vpc-id "$VPC_ID" \
        --cidr-block 10.0.1.0/24 \
        --availability-zone "$AWS_REGION"a \
        --query 'Subnet.SubnetId' \
        --output text)

    # Add a name tag to the subnet
    aws ec2 create-tags \
        --resources "$SUBNET_ID" \
        --tags "Key=Name,Value=$SUBNET_NAME"

    # Modify the subnet attribute to auto-assign public IPv4 on launch
    aws ec2 modify-subnet-attribute \
        --subnet-id "$SUBNET_ID" \
        --map-public-ip-on-launch
else
    echo -e "\033[0;32mSubnet already exists.\033[0m"
    SUBNET_ID=$SUBNET_CHECK
fi

echo -e "\033[0;32mCreating security group\033[0m"
SECURITY_GROUP_CHECK=$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null)

# Conditional check for security group existence
if [ -z "$SECURITY_GROUP_CHECK" ]; then
    # Create the security group
    SECURITY_GROUP_ID=$(aws ec2 create-security-group \
        --group-name "$SERVICE_NAME" \
        --description "$SERVICE_NAME security group" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' \
        --output text)

    # Add a name tag to the security group
    aws ec2 create-tags \
        --resources "$SECURITY_GROUP_ID" \
        --tags "Key=Name,Value=$SERVICE_NAME"

    # Authorize inbound traffic to the security group
    aws ec2 authorize-security-group-ingress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol tcp \
        --port 8888 \
        --cidr 0.0.0.0/0

    # Authorize outbound traffic from the security group
    aws ec2 authorize-security-group-egress \
        --group-id "$SECURITY_GROUP_ID" \
        --protocol all \
        --cidr 0.0.0.0/0
else
    echo -e "\033[0;32mSecurity group already exists.\033[0m"
    SECURITY_GROUP_ID=$SECURITY_GROUP_CHECK
fi

echo -e "\033[0;32mCreating ECS service\033[0m"

SERVICE_CHECK=$(aws ecs describe-services \
    --cluster "$ECS_CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION" \
    --query 'services[0].serviceName' \
    --output text 2>/dev/null)

# Conditional logic for service creation or update
if [ "$SERVICE_CHECK" == "$SERVICE_NAME" ]; then
    echo -e "\033[0;32mECS service already exists. Updating service...\033[0m"
    
    # Update existing service
    aws ecs update-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service "$SERVICE_NAME" \
        --task-definition "$TASK_DEFINITION_NAME" \
        --desired-count "$DESIRED_COUNT" \
        --region "$AWS_REGION"
else
    # Create new service
    aws ecs create-service \
        --cluster "$ECS_CLUSTER_NAME" \
        --service-name "$SERVICE_NAME" \
        --task-definition "$TASK_DEFINITION_NAME" \
        --desired-count "$DESIRED_COUNT" \
        --launch-type FARGATE \
        --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_ID],securityGroups=[$SECURITY_GROUP_ID],assignPublicIp=ENABLED}" \
        --region "$AWS_REGION"
fi

rm task-definition.json

echo -e "\033[0;32mYour ECS service is up and running!\033[0m"
