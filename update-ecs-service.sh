#!/bin/bash

# Update ECS Service to use latest CodeBuild image
# This script updates the ECS service to use the latest image built by CodeBuild

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
AWS_REGION=${AWS_REGION:-ap-south-1}
CLUSTER_NAME=${CLUSTER_NAME:-sourcestack-cluster}
SERVICE_NAME=${SERVICE_NAME:-sourcestack-api-service}
WORKER_SERVICE_NAME=${WORKER_SERVICE_NAME:-sourcestack-worker-service}

echo -e "${GREEN}Update ECS Service to Use CodeBuild Image${NC}"
echo "=============================================="
echo ""

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI is not installed.${NC}"
    exit 1
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo -e "${RED}Error: Could not get AWS account ID. Is AWS CLI configured?${NC}"
    exit 1
fi

ECR_IMAGE_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/source-stack-api:latest"

echo -e "${YELLOW}Configuration:${NC}"
echo "  Region: $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"
echo "  Image: $ECR_IMAGE_URI"
echo ""

# Verify image exists in ECR
echo -e "${GREEN}Step 1: Verifying image in ECR...${NC}"
if aws ecr describe-images --repository-name source-stack-api --image-ids imageTag=latest --region $AWS_REGION &> /dev/null; then
    IMAGE_INFO=$(aws ecr describe-images --repository-name source-stack-api --image-ids imageTag=latest --region $AWS_REGION --query 'imageDetails[0].[imagePushedAt,imageDigest]' --output text)
    echo -e "${GREEN}✓ Image found${NC}"
    echo "  Pushed at: $(echo $IMAGE_INFO | cut -f1)"
    echo "  Digest: $(echo $IMAGE_INFO | cut -f2)"
else
    echo -e "${RED}✗ Image not found in ECR. Make sure CodeBuild has built and pushed the image.${NC}"
    exit 1
fi
echo ""

# Update API service
if [ -n "$SERVICE_NAME" ]; then
    echo -e "${GREEN}Step 2: Updating ECS service: $SERVICE_NAME...${NC}"
    
    # Check if service exists
    if aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then
        echo "  Forcing new deployment to use latest image..."
        aws ecs update-service \
            --cluster $CLUSTER_NAME \
            --service $SERVICE_NAME \
            --force-new-deployment \
            --region $AWS_REGION \
            --query 'service.[serviceName,status,desiredCount,runningCount]' \
            --output table
        
        echo -e "${GREEN}✓ Service update initiated${NC}"
        echo ""
        echo "  Monitor deployment:"
        echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION --query 'services[0].deployments' --output table"
    else
        echo -e "${YELLOW}⚠ Service $SERVICE_NAME not found. Skipping...${NC}"
        echo "  Create the service first using ecs-task-definition.json"
    fi
    echo ""
fi

# Update worker service
if [ -n "$WORKER_SERVICE_NAME" ]; then
    echo -e "${GREEN}Step 3: Updating ECS worker service: $WORKER_SERVICE_NAME...${NC}"
    
    # Check if service exists
    if aws ecs describe-services --cluster $CLUSTER_NAME --services $WORKER_SERVICE_NAME --region $AWS_REGION --query 'services[0].status' --output text 2>/dev/null | grep -q "ACTIVE"; then
        echo "  Forcing new deployment to use latest image..."
        aws ecs update-service \
            --cluster $CLUSTER_NAME \
            --service $WORKER_SERVICE_NAME \
            --force-new-deployment \
            --region $AWS_REGION \
            --query 'service.[serviceName,status,desiredCount,runningCount]' \
            --output table
        
        echo -e "${GREEN}✓ Worker service update initiated${NC}"
    else
        echo -e "${YELLOW}⚠ Service $WORKER_SERVICE_NAME not found. Skipping...${NC}"
        echo "  Create the service first using ecs-worker-task-definition.json"
    fi
    echo ""
fi

echo -e "${GREEN}=============================================="
echo "Update Complete!"
echo "==============================================${NC}"
echo ""
echo "The ECS services will now use the latest image built by CodeBuild."
echo ""
echo "To monitor the deployment:"
echo "  aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME --region $AWS_REGION"
echo ""

