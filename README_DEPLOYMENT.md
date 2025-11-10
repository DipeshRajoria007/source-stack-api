# Deployment Overview

This document provides an overview of the deployment setup for SourceStack API.

## Where to Start

**If you're new to AWS deployment**, start with:
1. **[QUICK_START_AWS.md](./QUICK_START_AWS.md)** - Step-by-step guide to deploy in ~30 minutes

**For detailed information**, see:
2. **[DEPLOYMENT.md](./DEPLOYMENT.md)** - Comprehensive deployment guide with all options

## What's Been Set Up

### Configuration Files

1. **`ecs-task-definition.json`** - ECS Fargate task definition for the FastAPI application
2. **`ecs-worker-task-definition.json`** - ECS Fargate task definition for Celery workers
3. **`docker-compose.yml`** - Local development setup with API, worker, and Redis
4. **`.env.example`** - Template for environment variables (create `.env` from this)

### Scripts

1. **`deploy.sh`** - Manual script to build and push Docker image to ECR (for local builds)
2. **`update-ecs-service.sh`** - Updates ECS services to use latest CodeBuild image
3. **`setup-codebuild.sh`** - Sets up CodeBuild for automated CI/CD
4. **`iam-setup.sh`** - Creates necessary IAM roles and CloudWatch log groups

### Documentation

1. **`QUICK_START_AWS.md`** - Quick deployment guide (30 minutes)
2. **`DEPLOYMENT.md`** - Detailed deployment guide with all options
3. **`README.md`** - Application documentation

## Quick Start Commands

### 1. Set Up CodeBuild (Automated CI/CD) - Recommended
```bash
./setup-codebuild.sh
```
This sets up CodeBuild to automatically build and push Docker images on every GitHub push.

### 2. Set Up IAM Roles
```bash
./iam-setup.sh
```

### 3. Update ECS Service to Use CodeBuild Image
```bash
./update-ecs-service.sh
```

### 4. Manual Build (Alternative)
If you need to build locally instead of using CodeBuild:
```bash
./deploy.sh
```

### 5. Follow QUICK_START_AWS.md for remaining steps

## Architecture

```
┌──────────────┐
│   GitHub     │
└──────┬───────┘
       │ Push
       ▼
┌──────────────┐
│  CodeBuild   │──┐
└──────┬───────┘  │ Build & Push
       │          │
       ▼          ▼
┌──────────────┐  ┌──────────────┐
│     ECR      │◄─┘  Docker Image│
└──────┬───────┘     └──────────────┘
       │
       │ Pull
       ▼
┌──────────────┐
│   Internet   │
└──────┬───────┘
       │
       ▼
┌──────────────┐
│ Load Balancer│
└──────┬───────┘
       │
       ▼
┌──────────────┐      ┌──────────────┐
│  ECS Fargate │◄────►│  ElastiCache │
│  (FastAPI)   │      │  (Redis)     │
└──────┬───────┘      └──────────────┘
       │
       ▼
┌──────────────┐
│  ECS Fargate │
│ (Celery Worker)│
└──────────────┘
```

## Cost Estimate

With $200 AWS credit, estimated monthly costs:
- **ECS Fargate**: ~$15-30/month
- **ElastiCache Redis**: ~$15-20/month
- **Load Balancer**: ~$16/month
- **Data Transfer**: ~$5-10/month
- **Total**: ~$50-80/month

This leaves plenty of credit for scaling and additional services.

## Prerequisites

- AWS Account with $200 credit
- AWS CLI installed and configured
- Docker installed
- Basic terminal/command line knowledge

## CI/CD Pipeline

**CodeBuild is already configured!** Every time you push to GitHub:
1. CodeBuild automatically builds the Docker image
2. Image is pushed to ECR with `latest` and commit hash tags
3. Use `update-ecs-service.sh` to deploy the new image to ECS

To enable automatic deployments on push, set up GitHub webhooks in CodeBuild console.

## Next Steps After Deployment

1. ✅ CI/CD pipeline (CodeBuild) - Already set up!
2. Set up HTTPS with ACM certificate
3. Configure custom domain
4. Configure monitoring and alerts
5. Set up auto-scaling
6. Enable automatic ECS deployments via webhooks

## Need Help?

- Check the troubleshooting sections in QUICK_START_AWS.md and DEPLOYMENT.md
- AWS Documentation: https://docs.aws.amazon.com/
- ECS Documentation: https://docs.aws.amazon.com/ecs/

