# AWS CodeBuild Setup for SourceStack API

This guide helps you set up AWS CodeBuild to automatically build and push Docker images to ECR, avoiding local architecture issues.

## Why CodeBuild?

- ✅ Builds for correct platform (linux/amd64) automatically
- ✅ No local Docker/architecture issues
- ✅ Part of CI/CD pipeline
- ✅ Builds in AWS cloud
- ✅ Free tier: 100 build minutes/month

## Quick Setup

### Option 0: Use CodeBuild to Configure CodeBuild (Recommended)

The easiest way is to use CodeBuild itself to set up CodeBuild! See **[CODEBUILD_SETUP_USING_CODEBUILD.md](./CODEBUILD_SETUP_USING_CODEBUILD.md)** for details.

Quick start:
```bash
# Create the setup project
./create-setup-codebuild.sh

# Run the setup build
aws codebuild start-build --project-name sourcestack-setup-codebuild --region ap-south-1
```

### Option 1: Automated Setup Script

```bash
chmod +x setup-codebuild.sh
./setup-codebuild.sh
```

### Option 2: Manual Setup via Console

#### Step 1: Create IAM Role for CodeBuild

1. Go to **IAM Console** → **Roles** → **Create role**
2. **Trust entity**: AWS service → **CodeBuild**
3. **Permissions**: Attach these policies:
   - `CloudWatchLogsFullAccess`
   - `AWSCodeBuildDeveloperAccess`
   - Create inline policy for ECR:
     ```json
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
     ```
4. **Role name**: `codebuild-sourcestack-api-service-role`

#### Step 2: Create CodeBuild Project

1. Go to **CodeBuild Console** → **Create build project**
2. **Project name**: `sourcestack-api-build`
3. **Source**:
   - **Source provider**: GitHub (or S3 for manual uploads)
   - **Repository**: Your GitHub repo (or S3 bucket)
   - **Buildspec**: Use `buildspec.yml` from repo
4. **Environment**:
   - **Environment image**: Managed image
   - **Operating system**: Ubuntu
   - **Runtime(s)**: Standard
   - **Image**: `aws/codebuild/standard:7.0`
   - **Image version**: Latest
   - **Environment type**: Linux
   - **Compute type**: `BUILD_GENERAL1_SMALL` (or `BUILD_GENERAL1_MEDIUM` for faster builds)
   - **Privileged**: ✅ **Enabled** (required for Docker)
5. **Service role**: Select `codebuild-sourcestack-api-service-role`
6. **Buildspec**: `buildspec.yml` (or leave default)
7. **Environment variables**:
   - `AWS_ACCOUNT_ID`: Your AWS account ID (get it with `aws sts get-caller-identity --query Account --output text`)
   - `AWS_DEFAULT_REGION`: `ap-south-1` (or your preferred region)
8. Click **Create build project**

#### Step 3: Start Build

**If using GitHub:**
- CodeBuild will automatically build on push (if configured)
- Or manually trigger: CodeBuild → Your project → Start build

**If using S3:**
```bash
# Create S3 bucket
aws s3 mb s3://sourcestack-api-source --region ap-south-1

# Zip source code
zip -r build.zip . -x '*.git*' 'venv/*' '*.pyc' '__pycache__/*' 'node_modules/*'

# Upload to S3
aws s3 cp build.zip s3://sourcestack-api-source/build.zip

# Start build
aws codebuild start-build --project-name sourcestack-api-build --region ap-south-1
```

## Buildspec.yml

The `buildspec.yml` file is already created in your repo. It:
- Logs into ECR
- Builds Docker image for linux/amd64
- Tags with `latest` and commit hash
- Pushes to ECR

## After Build Completes

1. Check ECR repository - you should see new image with `latest` tag
2. Update ECS service to use new image:
   ```bash
   aws ecs update-service \
     --cluster sourcestack-cluster \
     --service sourcestack-api-service \
     --force-new-deployment \
     --region ap-south-1
   ```

## GitHub Integration (Optional)

To automatically build on every push:

1. In CodeBuild project → **Source** → **Edit**
2. Enable **Webhook** → **Rebuild every time a code change is pushed**
3. Connect GitHub account if needed
4. Save

## Cost

- **Free tier**: 100 build minutes/month
- **BUILD_GENERAL1_SMALL**: ~$0.01/minute (~$0.60/hour)
- **BUILD_GENERAL1_MEDIUM**: ~$0.02/minute (~$1.20/hour)

For your use case, small instance is sufficient (~5-10 minutes per build).

## Troubleshooting

### Build fails with "Cannot connect to Docker daemon"
- Ensure **Privileged** mode is enabled in environment settings

### Build fails with ECR authentication
- Check IAM role has ECR permissions
- Verify environment variables are set correctly

### Image not found in ECR
- Check build logs in CloudWatch
- Verify ECR repository name matches in buildspec.yml

## Next Steps

1. Set up CodeBuild (use script or console)
2. Run first build
3. Verify image in ECR
4. Update ECS service to use new image
5. (Optional) Set up GitHub webhook for automatic builds

