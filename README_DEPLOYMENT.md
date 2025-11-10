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

1. **`deploy.sh`** - Automated script to build and push Docker image to ECR
2. **`iam-setup.sh`** - Creates necessary IAM roles and CloudWatch log groups

### Documentation

1. **`QUICK_START_AWS.md`** - Quick deployment guide (30 minutes)
2. **`DEPLOYMENT.md`** - Detailed deployment guide with all options
3. **`README.md`** - Application documentation

## Quick Start Commands

### 1. Set Up IAM Roles
```bash
./iam-setup.sh
```

### 2. Build and Push Docker Image
```bash
./deploy.sh
```

### 3. Follow QUICK_START_AWS.md for remaining steps

## Architecture

```
┌─────────────────┐
│   Internet      │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Load Balancer  │
└────────┬────────┘
         │
         ▼
┌─────────────────┐      ┌──────────────┐
│  ECS Fargate    │◄────►│  ElastiCache │
│  (FastAPI)      │      │  (Redis)     │
└─────────────────┘      └──────────────┘
         │
         ▼
┌─────────────────┐
│  ECS Fargate    │
│  (Celery Worker)│
└─────────────────┘
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

## Next Steps After Deployment

1. Set up HTTPS with ACM certificate
2. Configure custom domain
3. Set up CI/CD pipeline
4. Configure monitoring and alerts
5. Set up auto-scaling

## Need Help?

- Check the troubleshooting sections in QUICK_START_AWS.md and DEPLOYMENT.md
- AWS Documentation: https://docs.aws.amazon.com/
- ECS Documentation: https://docs.aws.amazon.com/ecs/

