# CodeBuild Deployment Guide

This guide explains how to deploy using CodeBuild, which automatically builds and pushes Docker images on every GitHub push.

## Overview

CodeBuild is configured to:
- ✅ Build Docker images automatically on GitHub push
- ✅ Push images to ECR with `latest` and commit hash tags
- ✅ Build for correct platform (linux/amd64)
- ✅ No local Docker/architecture issues

## Current Setup

- **CodeBuild Project**: `sourcestack-api-build`
- **ECR Repository**: `source-stack-api`
- **Region**: `ap-south-1`
- **Image URI**: `879383178244.dkr.ecr.ap-south-1.amazonaws.com/source-stack-api:latest`

## Deployment Workflow

### 1. Code Changes
Make your code changes and commit:
```bash
git add .
git commit -m "Your changes"
git push origin main
```

### 2. Automatic Build
CodeBuild automatically:
- Detects the GitHub push
- Downloads source code
- Builds Docker image
- Pushes to ECR with tags: `latest` and commit hash (e.g., `acf0054`)

### 3. Deploy to ECS
Update your ECS service to use the new image:

```bash
# Automatic update script
./update-ecs-service.sh

# Or manually
aws ecs update-service \
    --cluster sourcestack-cluster \
    --service sourcestack-api-service \
    --force-new-deployment \
    --region ap-south-1
```

## Task Definitions

Task definitions are already configured to use the CodeBuild image:
- **API**: `ecs-task-definition.json` → Uses `879383178244.dkr.ecr.ap-south-1.amazonaws.com/source-stack-api:latest`
- **Worker**: `ecs-worker-task-definition.json` → Uses same image

## Monitoring Builds

### Check Build Status
```bash
# List recent builds
aws codebuild list-builds-for-project \
    --project-name sourcestack-api-build \
    --region ap-south-1 \
    --max-items 5

# Get build details
BUILD_ID=$(aws codebuild list-builds-for-project \
    --project-name sourcestack-api-build \
    --region ap-south-1 \
    --max-items 1 \
    --query 'ids[0]' --output text)

aws codebuild batch-get-builds \
    --ids $BUILD_ID \
    --region ap-south-1 \
    --query 'builds[0].[buildStatus,currentPhase,sourceVersion]' \
    --output table
```

### View Build Logs
1. Go to CodeBuild Console: https://ap-south-1.console.aws.amazon.com/codesuite/codebuild/home?region=ap-south-1
2. Click on `sourcestack-api-build`
3. Click on the build to view logs

## Verify ECR Images

```bash
# List all images
aws ecr describe-images \
    --repository-name source-stack-api \
    --region ap-south-1 \
    --query 'imageDetails[*].[imageTags[0],imagePushedAt]' \
    --output table

# Get latest image
aws ecr describe-images \
    --repository-name source-stack-api \
    --image-ids imageTag=latest \
    --region ap-south-1 \
    --query 'imageDetails[0].[imageTags,imagePushedAt,imageDigest]' \
    --output json
```

## Enable Automatic Deployments (Optional)

To automatically deploy to ECS when CodeBuild succeeds:

1. **Set up CodePipeline** (recommended):
   - Create a pipeline that triggers on CodeBuild success
   - Add ECS deployment action

2. **Use EventBridge**:
   - Create rule for CodeBuild success events
   - Trigger Lambda to update ECS service

3. **Manual** (current):
   - Run `./update-ecs-service.sh` after each build

## Troubleshooting

### Build Fails
1. Check CodeBuild logs in CloudWatch
2. Verify `buildspec.yml` is in repository root
3. Check GitHub connection is authorized
4. Verify ECR permissions

### Image Not Found in ECR
1. Check build completed successfully
2. Verify ECR repository name matches: `source-stack-api`
3. Check region matches: `ap-south-1`

### ECS Service Not Updating
1. Verify task definition uses correct image URI
2. Check ECS service is running
3. Verify IAM roles have ECR pull permissions
4. Check CloudWatch logs for errors

## Manual Override

If you need to build locally instead of using CodeBuild:

```bash
# Use the deploy script
./deploy.sh

# Then update ECS service
./update-ecs-service.sh
```

## Best Practices

1. **Always test locally** before pushing
2. **Monitor builds** in CodeBuild console
3. **Use commit messages** to track deployments
4. **Tag images** with version numbers for production
5. **Set up alerts** for build failures

## Cost

- **CodeBuild**: Free tier includes 100 build minutes/month
- **ECR**: ~$0.10 per GB/month for storage
- **Data Transfer**: Free within same region

For typical usage, CodeBuild costs are minimal (well within free tier).

