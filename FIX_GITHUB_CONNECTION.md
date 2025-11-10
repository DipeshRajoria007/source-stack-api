# Fix CodeBuild GitHub Connection Issue

The build is failing because CodeBuild cannot access your GitHub repository. This is a common issue that requires GitHub OAuth authorization.

## Error Message
```
stat /codebuild/output/src2212522110/src/github.com/DipeshRajoria007/source-stack-api/buildspec.yml: no such file or directory
```

## Solution: Authorize GitHub Connection

### Step 1: Go to CodeBuild Console
1. Open AWS Console: https://ap-south-1.console.aws.amazon.com/codesuite/codebuild/home?region=ap-south-1
2. Click on project: **sourcestack-api-build**

### Step 2: Update Source and Authorize GitHub
1. Click **Edit** → **Source**
2. Under **Source provider**, select **GitHub**
3. Click **Connect to GitHub** (or **Reconnect** if already connected)
4. You'll be redirected to GitHub to authorize AWS CodeBuild
5. Authorize the connection
6. Select your repository: `DipeshRajoria007/source-stack-api`
7. Select branch: `main`
8. **Buildspec**: `buildspec.yml` (should be auto-filled)
9. Click **Update source**

### Step 3: Retry Build
After authorization, start a new build:
```bash
aws codebuild start-build --project-name sourcestack-api-build --region ap-south-1
```

## Alternative: Use S3 Source (No GitHub Auth Needed)

If you prefer not to use GitHub OAuth, you can switch to S3 source:

1. **Create S3 bucket** (if not exists):
   ```bash
   aws s3 mb s3://sourcestack-api-source --region ap-south-1
   ```

2. **Zip and upload source**:
   ```bash
   zip -r build.zip . -x '*.git*' 'venv/*' '*.pyc' '__pycache__/*' 'node_modules/*'
   aws s3 cp build.zip s3://sourcestack-api-source/build.zip
   ```

3. **Update CodeBuild project to use S3**:
   ```bash
   aws codebuild update-project \
       --name sourcestack-api-build \
       --source type=S3,location=sourcestack-api-source/build.zip,buildspec=buildspec.yml \
       --region ap-south-1
   ```

## Verify buildspec.yml is in Repository

Make sure `buildspec.yml` is committed and pushed:
```bash
# Check if file exists
ls -la buildspec.yml

# Check if it's tracked
git ls-files buildspec.yml

# Push to GitHub if needed
git add buildspec.yml
git commit -m "Add buildspec.yml"
git push origin main
```

## After Fixing

Once GitHub is authorized or you switch to S3, the build should work. The build will:
1. Download source code
2. Run buildspec.yml
3. Build Docker image
4. Push to ECR

