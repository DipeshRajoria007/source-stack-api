# Using CodeBuild to Configure CodeBuild

This guide shows you how to use CodeBuild itself to set up the CodeBuild project for building Docker images. This is a meta-configuration approach that automates the setup process.

## Overview

Instead of manually running `setup-codebuild.sh`, you can create a one-time CodeBuild project that runs the setup script. This is useful for:
- Automating initial setup
- Ensuring consistent configuration
- Making setup repeatable

## Step-by-Step Guide

### Step 1: Create Initial CodeBuild Project (One-Time Manual Setup)

You need to create a minimal CodeBuild project manually that will run the setup script. This is a one-time setup.

#### Option A: Using AWS Console

1. Go to **CodeBuild Console** → **Create build project**
2. **Project name**: `sourcestack-setup-codebuild`
3. **Source**:
   - **Source provider**: GitHub (or S3)
   - **Repository**: Your GitHub repo
   - **Buildspec**: `buildspec-setup.yml`
4. **Environment**:
   - **Environment image**: Managed image
   - **Operating system**: Ubuntu
   - **Runtime(s)**: Standard
   - **Image**: `aws/codebuild/standard:7.0`
   - **Image version**: Latest
   - **Environment type**: Linux
   - **Compute type**: `BUILD_GENERAL1_SMALL`
   - **Privileged**: ❌ Not needed for this setup
5. **Service role**: Create new service role (CodeBuild will create it automatically)
6. **Buildspec**: `buildspec-setup.yml`
7. **Environment variables**:
   - `AWS_DEFAULT_REGION`: `ap-south-1` (or your region)
8. Click **Create build project**

#### Option B: Using AWS CLI

```bash
# Create a basic IAM role for the setup project
aws iam create-role \
    --role-name codebuild-setup-service-role \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "codebuild.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }'

# Attach basic policies
aws iam attach-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

aws iam attach-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-arn arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess

# Attach IAM full access (needed to create roles and policies)
aws iam attach-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name codebuild-setup-service-role --query 'Role.Arn' --output text)

# Create CodeBuild project
aws codebuild create-project \
    --name sourcestack-setup-codebuild \
    --source type=GITHUB,location=https://github.com/YOUR_USERNAME/YOUR_REPO.git,buildspec=buildspec-setup.yml \
    --artifacts type=NO_ARTIFACTS \
    --environment type=LINUX_CONTAINER,image=aws/codebuild/standard:7.0,computeType=BUILD_GENERAL1_SMALL \
    --service-role $ROLE_ARN \
    --region ap-south-1 \
    --environment-variables name=AWS_DEFAULT_REGION,value=ap-south-1 \
    --buildspec buildspec-setup.yml
```

**Note**: Replace `YOUR_USERNAME/YOUR_REPO` with your actual GitHub repository.

### Step 2: Run the Setup Build

Once the setup project is created, start a build:

```bash
aws codebuild start-build \
    --project-name sourcestack-setup-codebuild \
    --region ap-south-1
```

Or use the AWS Console:
1. Go to CodeBuild → `sourcestack-setup-codebuild`
2. Click **Start build**

### Step 3: Monitor the Build

Watch the build logs in CloudWatch or the CodeBuild console. The setup script will:
1. Create IAM role for the main CodeBuild project
2. Attach necessary policies
3. Create the main CodeBuild project (`sourcestack-api-build`)

### Step 4: Use the Main CodeBuild Project

After the setup build completes successfully, you can use the main project:

```bash
# Start a build with the main project
aws codebuild start-build \
    --project-name sourcestack-api-build \
    --region ap-south-1
```

## What Gets Created

The setup build creates:

1. **IAM Role**: `codebuild-sourcestack-api-service-role`
   - CloudWatch Logs access
   - CodeBuild developer access
   - ECR access (inline policy)

2. **CodeBuild Project**: `sourcestack-api-build`
   - Configured to build Docker images
   - Pushes to ECR
   - Uses `buildspec.yml` for builds

## Cleanup

After setup is complete, you can optionally delete the setup project:

```bash
aws codebuild delete-project \
    --name sourcestack-setup-codebuild \
    --region ap-south-1

# Optionally delete the setup service role
aws iam delete-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-name IAMFullAccess

aws iam detach-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

aws iam detach-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

aws iam detach-role-policy \
    --role-name codebuild-setup-service-role \
    --policy-arn arn:aws:iam::aws:policy/AWSCodeBuildDeveloperAccess

aws iam delete-role \
    --role-name codebuild-setup-service-role
```

## Troubleshooting

### Build fails with "Access Denied"
- Ensure the setup project's service role has `IAMFullAccess` policy
- Check that the role has permissions to create CodeBuild projects

### Build fails with "Role already exists"
- This is normal if you've run the setup before
- The script will update existing resources instead of failing

### Setup project can't find setup-codebuild.sh
- Ensure `buildspec-setup.yml` is in the repository root
- Verify the source repository is correctly configured

## Next Steps

After the setup build completes:
1. Verify the main project exists: `aws codebuild list-projects`
2. Run your first Docker build: `aws codebuild start-build --project-name sourcestack-api-build`
3. Check ECR for the new image
4. Update your ECS service to use the new image

