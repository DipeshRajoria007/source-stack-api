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
    
    # Use GitHub source (detect from git remote if available)
    GITHUB_REPO=""
    if command -v git &> /dev/null && git remote get-url origin &> /dev/null; then
        GIT_REMOTE=$(git remote get-url origin)
        # Convert SSH URL to HTTPS if needed
        if [[ $GIT_REMOTE == git@github.com:* ]]; then
            GITHUB_REPO=$(echo $GIT_REMOTE | sed 's|git@github.com:|https://github.com/|' | sed 's|\.git$|.git|')
        elif [[ $GIT_REMOTE == https://github.com/* ]]; then
            GITHUB_REPO=$GIT_REMOTE
        fi
    fi
    
    if [ -z "$GITHUB_REPO" ]; then
        echo "GitHub repo not detected. Using S3 source..."
        echo "Creating S3 bucket first..."
        
        # Create S3 bucket if it doesn't exist
        BUCKET_NAME="sourcestack-api-source"
        if ! aws s3 ls "s3://$BUCKET_NAME" 2>&1 | grep -q 'NoSuchBucket'; then
            echo "Bucket $BUCKET_NAME already exists"
        else
            aws s3 mb "s3://$BUCKET_NAME" --region $AWS_REGION || echo "Bucket creation failed or already exists"
        fi
        
        # Create temporary JSON file for project configuration with S3 source
        cat > /tmp/codebuild-project.json <<EOF
{
  "name": "$PROJECT_NAME",
  "source": {
    "type": "S3",
    "location": "$BUCKET_NAME/build.zip",
    "buildspec": "$BUILDSPEC_PATH"
  },
  "artifacts": {
    "type": "NO_ARTIFACTS"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      {
        "name": "AWS_ACCOUNT_ID",
        "value": "$AWS_ACCOUNT_ID"
      },
      {
        "name": "AWS_DEFAULT_REGION",
        "value": "$AWS_REGION"
      }
    ]
  },
  "serviceRole": "$ROLE_ARN",
  "timeoutInMinutes": 60
}
EOF
    else
        echo "Using GitHub source: $GITHUB_REPO"
        
        # Create temporary JSON file for project configuration with GitHub source
        cat > /tmp/codebuild-project.json <<EOF
{
  "name": "$PROJECT_NAME",
  "source": {
    "type": "GITHUB",
    "location": "$GITHUB_REPO",
    "buildspec": "$BUILDSPEC_PATH"
  },
  "artifacts": {
    "type": "NO_ARTIFACTS"
  },
  "environment": {
    "type": "LINUX_CONTAINER",
    "image": "aws/codebuild/standard:7.0",
    "computeType": "BUILD_GENERAL1_SMALL",
    "privilegedMode": true,
    "environmentVariables": [
      {
        "name": "AWS_ACCOUNT_ID",
        "value": "$AWS_ACCOUNT_ID"
      },
      {
        "name": "AWS_DEFAULT_REGION",
        "value": "$AWS_REGION"
      }
    ]
  },
  "serviceRole": "$ROLE_ARN",
  "timeoutInMinutes": 60
}
EOF
    fi
    
    aws codebuild create-project \
        --cli-input-json file:///tmp/codebuild-project.json \
        --region $AWS_REGION
    
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

