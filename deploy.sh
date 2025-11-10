#!/bin/bash

# SourceStack API Deployment Script
# NOTE: This script is for manual local builds. 
# CodeBuild automatically builds and pushes images on every GitHub push.
# Use update-ecs-service.sh to update ECS services with CodeBuild images.

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION=${AWS_REGION:-ap-south-1}
ECR_REPO_NAME="source-stack-api"
IMAGE_TAG=${IMAGE_TAG:-latest}

echo -e "${GREEN}SourceStack API Deployment Script${NC}"
echo "=================================="

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed. Please install it first.${NC}"
    exit 1
fi

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Error: Docker is not installed. Please install it first.${NC}"
    exit 1
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Could not get AWS account ID. Is AWS CLI configured?${NC}"
    exit 1
fi

ECR_REPO_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO_NAME}"

echo -e "${YELLOW}AWS Account ID: ${AWS_ACCOUNT_ID}${NC}"
echo -e "${YELLOW}Region: ${AWS_REGION}${NC}"
echo -e "${YELLOW}ECR Repository: ${ECR_REPO_URI}${NC}"
echo ""

# Step 1: Create ECR repository if it doesn't exist
echo -e "${GREEN}Step 1: Checking ECR repository...${NC}"
if aws ecr describe-repositories --repository-names ${ECR_REPO_NAME} --region ${AWS_REGION} &> /dev/null; then
    echo -e "${GREEN}Repository already exists${NC}"
else
    echo -e "${YELLOW}Creating ECR repository...${NC}"
    aws ecr create-repository --repository-name ${ECR_REPO_NAME} --region ${AWS_REGION}
    echo -e "${GREEN}Repository created${NC}"
fi

# Step 2: Authenticate Docker to ECR
echo -e "${GREEN}Step 2: Authenticating Docker to ECR...${NC}"
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REPO_URI}

# Step 3: Build Docker image
echo -e "${GREEN}Step 3: Building Docker image...${NC}"
docker build -t ${ECR_REPO_NAME}:${IMAGE_TAG} .

# Step 4: Tag image for ECR
echo -e "${GREEN}Step 4: Tagging image...${NC}"
docker tag ${ECR_REPO_NAME}:${IMAGE_TAG} ${ECR_REPO_URI}:${IMAGE_TAG}

# Step 5: Push image to ECR
echo -e "${GREEN}Step 5: Pushing image to ECR...${NC}"
docker push ${ECR_REPO_URI}:${IMAGE_TAG}

echo ""
echo -e "${GREEN}✓ Image pushed successfully!${NC}"
echo ""
echo -e "${YELLOW}Note: CodeBuild automatically builds images on GitHub push.${NC}"
echo -e "${YELLOW}For production, use CodeBuild instead of this script.${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Update ECS service to use the new image:"
echo "   ./update-ecs-service.sh"
echo ""
echo "2. Or manually update ECS service:"
echo "   aws ecs update-service \\"
echo "     --cluster sourcestack-cluster \\"
echo "     --service sourcestack-api-service \\"
echo "     --force-new-deployment \\"
echo "     --region ${AWS_REGION}"
echo ""
echo "3. Register/update task definition (if needed):"
echo "   aws ecs register-task-definition --cli-input-json file://ecs-task-definition.json --region ${AWS_REGION}"
echo ""
echo -e "${GREEN}Deployment script completed!${NC}"

