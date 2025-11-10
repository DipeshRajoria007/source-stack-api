#!/bin/bash

# Create the initial CodeBuild project that will run setup-codebuild.sh
# This is a one-time setup script

set -e

AWS_REGION=${AWS_DEFAULT_REGION:-${AWS_REGION:-ap-south-1}}
SETUP_PROJECT_NAME="sourcestack-setup-codebuild"
SETUP_ROLE_NAME="codebuild-setup-service-role"

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Error: Could not get AWS account ID. Is AWS CLI configured?"
    exit 1
fi

echo "AWS Account ID: $AWS_ACCOUNT_ID"
echo "Region: $AWS_REGION"
echo ""

# Step 1: Create IAM role for setup project
echo "Step 1: Creating IAM role for setup project..."

# Create trust policy
cat > /tmp/setup-trust-policy.json <<EOF
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
if aws iam get-role --role-name $SETUP_ROLE_NAME &> /dev/null; then
    echo "Role $SETUP_ROLE_NAME already exists"
else
    aws iam create-role \
        --role-name $SETUP_ROLE_NAME \
        --assume-role-policy-document file:///tmp/setup-trust-policy.json
    
    echo "✓ Created IAM role: $SETUP_ROLE_NAME"
fi

# Attach policies
echo "Attaching policies..."
aws iam attach-role-policy \
    --role-name $SETUP_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess || echo "Policy already attached"

aws iam attach-role-policy \
    --role-name $SETUP_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess || echo "Policy already attached"

# Attach IAM full access (needed to create roles and CodeBuild projects)
aws iam attach-role-policy \
    --role-name $SETUP_ROLE_NAME \
    --policy-arn arn:aws:iam::aws:policy/IAMFullAccess || echo "Policy already attached"

echo "✓ Attached policies to IAM role"
echo ""

# Wait for role to be ready
echo "Waiting for IAM role to be ready..."
sleep 5

# Step 2: Create CodeBuild project
echo "Step 2: Creating CodeBuild setup project..."

# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name $SETUP_ROLE_NAME --query 'Role.Arn' --output text)

# Check if project exists
if aws codebuild describe-projects --names $SETUP_PROJECT_NAME --region $AWS_REGION &> /dev/null; then
    echo "CodeBuild project already exists. Updating..."
    
    # For GitHub source (update with your repo)
    read -p "Enter your GitHub repository URL (e.g., https://github.com/username/repo.git): " GITHUB_REPO
    
    aws codebuild update-project \
        --name $SETUP_PROJECT_NAME \
        --source type=GITHUB,location=$GITHUB_REPO,buildspec=buildspec-setup.yml \
        --artifacts type=NO_ARTIFACTS \
        --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL \
        --service-role $ROLE_ARN \
        --region $AWS_REGION \
        --environment-variables name=AWS_DEFAULT_REGION,value=$AWS_REGION \
        --buildspec buildspec-setup.yml
    
    echo "✓ Updated CodeBuild project"
else
    echo "Creating new CodeBuild project..."
    
    # Prompt for GitHub repo
    read -p "Enter your GitHub repository URL (e.g., https://github.com/username/repo.git): " GITHUB_REPO
    
    aws codebuild create-project \
        --name $SETUP_PROJECT_NAME \
        --source type=GITHUB,location=$GITHUB_REPO,buildspec=buildspec-setup.yml \
        --artifacts type=NO_ARTIFACTS \
        --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL \
        --service-role $ROLE_ARN \
        --region $AWS_REGION \
        --environment-variables name=AWS_DEFAULT_REGION,value=$AWS_REGION \
        --buildspec buildspec-setup.yml
    
    echo "✓ Created CodeBuild project"
fi

echo ""
echo "=========================================="
echo "Setup CodeBuild Project Created!"
echo "=========================================="
echo ""
echo "Project Name: $SETUP_PROJECT_NAME"
echo "Service Role: $ROLE_ARN"
echo ""
echo "Next steps:"
echo "1. Start the setup build:"
echo "   aws codebuild start-build --project-name $SETUP_PROJECT_NAME --region $AWS_REGION"
echo ""
echo "2. Monitor the build in CodeBuild console or CloudWatch"
echo ""
echo "3. After setup completes, use the main project:"
echo "   aws codebuild start-build --project-name sourcestack-api-build --region $AWS_REGION"
echo ""

