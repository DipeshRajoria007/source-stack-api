#!/bin/bash

# Setup CodeBuild for SourceStack API
# This script creates a CodeBuild project to build and push Docker images to ECR

set -e

# Use CodeBuild environment variables if available, otherwise use defaults
AWS_REGION=${AWS_DEFAULT_REGION:-${AWS_REGION:-ap-south-1}}
PROJECT_NAME="sourcestack-api-build"
ECR_REPO_NAME="source-stack-api"
SERVICE_ROLE_NAME="codebuild-sourcestack-api-service-role"

# Get AWS account ID (use CodeBuild env var if available)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    if [ -z "$AWS_ACCOUNT_ID" ]; then
        echo "Error: Could not get AWS account ID. Is AWS CLI configured?"
        exit 1
    fi
fi

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo ""

# Step 1: Create IAM role for CodeBuild
echo "Step 1: Creating IAM role for CodeBuild..."

# Create trust policy
cat > /tmp/codebuild-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

# Create role
if aws iam get-role --role-name $SERVICE_ROLE_NAME &> /dev/null; then
    echo "Role $SERVICE_ROLE_NAME already exists"
else
    aws iam create-role \
        --role-name $SERVICE_ROLE_NAME \
        --assume-role-policy-document file:///tmp/codebuild-trust-policy.json
    
    echo "✓ Created IAM role: $SERVICE_ROLE_NAME"
fi

# Attach policies
echo "Attaching policies..."
aws iam attach-role-policy \
    --role-name $SERVICE_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || echo "Policy already attached"

aws iam attach-role-policy \
    --role-name $SERVICE_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess || echo "Policy already attached"

# Create inline policy for ECR access
cat > /tmp/ecr-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
    --role-name $SERVICE_ROLE_NAME \
    --policy-name ECRAccess \
    --policy-document file:///tmp/ecr-policy.json || echo "ECR policy already exists"

echo "✓ Attached policies to IAM role"
echo ""

# Wait for role to be ready (IAM eventual consistency)
echo "Waiting for IAM role to be ready..."
sleep 5

# Step 2: Create CodeBuild project
echo "Step 2: Creating CodeBuild project..."

# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name $SERVICE_ROLE_NAME --query 'Role.Arn' --output text)

# Create buildspec file path (assuming it's in the repo root)
BUILDSPEC_PATH="buildspec.yml"

# Check if CodeBuild project exists
if aws codebuild describe-projects --names $PROJECT_NAME --region $AWS_REGION &> /dev/null; then
    echo "CodeBuild project already exists. Updating..."
    
    aws codebuild update-project \
        --name $PROJECT_NAME \
        --source type=GITHUB,location=https://github.com/YOUR_USERNAME/YOUR_REPO.git,buildspec=$BUILDSPEC_PATH \
        --artifacts type=NO_ARTIFACTS \
        --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
        --service-role $ROLE_ARN \
        --region $AWS_REGION \
        --timeout-in-minutes 60
    
    echo "✓ Updated CodeBuild project"
else
    echo "Creating new CodeBuild project..."
    
    # For GitHub source (update with your repo)
    # aws codebuild create-project \
    #     --name $PROJECT_NAME \
    #     --source type=GITHUB,location=https://github.com/YOUR_USERNAME/YOUR_REPO.git,buildspec=$BUILDSPEC_PATH \
    #     --artifacts type=NO_ARTIFACTS \
    #     --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
    #     --service-role $ROLE_ARN \
    #     --region $AWS_REGION \
    #     --timeout-in-minutes 60
    
    # For S3 source (easier for manual builds)
    echo "Creating project with S3 source (you'll upload source manually)..."
    
    aws codebuild create-project \
        --name $PROJECT_NAME \
        --source type=S3,location=sourcestack-api-source/build.zip \
        --artifacts type=NO_ARTIFACTS \
        --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL,privilegedMode=true \
        --service-role $ROLE_ARN \
        --region $AWS_REGION \
        --timeout-in-minutes 60 \
        --environment-variables name=AWS_ACCOUNT_ID,value=$AWS_ACCOUNT_ID name=AWS_DEFAULT_REGION,value=$AWS_REGION \
        --buildspec $BUILDSPEC_PATH
    
    echo "✓ Created CodeBuild project"
fi

echo ""
echo "=========================================="
echo "CodeBuild Setup Complete!"
echo "=========================================="
echo ""
echo "Project Name: $PROJECT_NAME"
echo "Service Role: $ROLE_ARN"
echo ""
echo "Next steps:"
echo "1. Create S3 bucket for source:"
echo "   aws s3 mb s3://sourcestack-api-source --region $AWS_REGION"
echo ""
echo "2. Upload source code:"
echo "   zip -r build.zip . -x '*.git*' 'venv/*' '*.pyc' '__pycache__/*'"
echo "   aws s3 cp build.zip s3://sourcestack-api-source/build.zip"
echo ""
echo "3. Start build:"
echo "   aws codebuild start-build --project-name $PROJECT_NAME --region $AWS_REGION"
echo ""
echo "Or use GitHub integration (update the script with your repo URL)"

