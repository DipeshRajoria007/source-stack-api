# Troubleshooting Guide

## Common ECS Deployment Issues

### 1. Circuit Breaker Rollback - Platform Mismatch

**Error:**
```
Service deployment rolled back because the circuit breaker threshold was exceeded.
CannotPullContainerError: image Manifest does not contain descriptor matching platform 'linux/amd64'
```

**Cause:**
ECS Fargate requires `linux/amd64` images, but the Docker image was built for a different platform (e.g., ARM64).

**Solution:**
✅ **Fixed!** The `buildspec.yml` now builds for `linux/amd64` platform:
```yaml
docker build --platform linux/amd64 -t $REPOSITORY_URI:latest .
```

**Next Steps:**
1. CodeBuild will automatically rebuild with the correct platform
2. Wait for the build to complete
3. Update ECS service:
   ```bash
   ./update-ecs-service.sh
   ```

---

### 2. Health Check Failures

**Error:**
```
(service sourcestack-api-service) (deployment ...) deployment failed: tasks failed health checks
```

**Causes:**
- Application not responding on health check endpoint
- Health check endpoint doesn't exist (`/health`)
- Application taking too long to start
- Wrong port configuration

**Solutions:**

1. **Verify health check endpoint exists:**
   ```python
   # In app/main.py
   @app.get("/health")
   def health():
       return {"status": "healthy"}
   ```

2. **Adjust health check timing in task definition:**
   ```json
   "healthCheck": {
     "command": ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"],
     "interval": 30,
     "timeout": 5,
     "retries": 3,
     "startPeriod": 120  // Increase if app takes longer to start
   }
   ```

3. **Check CloudWatch logs:**
   ```bash
   aws logs tail /ecs/sourcestack-api --follow --region ap-south-1
   ```

---

### 3. Cannot Pull Container Error

**Error:**
```
CannotPullContainerError: pull image manifest has been retried 7 time(s)
```

**Causes:**
- Image doesn't exist in ECR
- Wrong image URI in task definition
- ECS task execution role lacks ECR permissions
- Image was deleted from ECR

**Solutions:**

1. **Verify image exists:**
   ```bash
   aws ecr describe-images \
       --repository-name source-stack-api \
       --image-ids imageTag=latest \
       --region ap-south-1
   ```

2. **Check task execution role permissions:**
   - Role: `ecsTaskExecutionRole`
   - Needs: `AmazonEC2ContainerRegistryReadOnly` policy

3. **Verify image URI in task definition:**
   ```bash
   aws ecs describe-task-definition \
       --task-definition sourcestack-api \
       --region ap-south-1 \
       --query 'taskDefinition.containerDefinitions[0].image'
   ```

---

### 4. Tasks Failing to Start

**Error:**
```
(deployment ...) deployment failed: tasks failed to start
```

**Causes:**
- Container crashes immediately
- Missing environment variables
- Wrong command/entrypoint
- Resource constraints (CPU/memory)

**Solutions:**

1. **Check stopped tasks:**
   ```bash
   aws ecs list-tasks \
       --cluster sourcestack-cluster \
       --desired-status STOPPED \
       --region ap-south-1
   
   # Get stopped reason
   aws ecs describe-tasks \
       --cluster sourcestack-cluster \
       --tasks <task-id> \
       --region ap-south-1 \
       --query 'tasks[0].stoppedReason'
   ```

2. **Check CloudWatch logs:**
   ```bash
   aws logs tail /ecs/sourcestack-api --follow --region ap-south-1
   ```

3. **Verify environment variables:**
   - Check `ecs-task-definition.json` has all required env vars
   - Verify Redis URL is correct
   - Check API_KEY is set

4. **Test locally:**
   ```bash
   docker run -p 8000:8000 \
       -e API_KEY=test \
       -e REDIS_URL=redis://... \
       879383178244.dkr.ecr.ap-south-1.amazonaws.com/source-stack-api:latest
   ```

---

### 5. Service Stuck in Deployment

**Symptoms:**
- Service shows "ACTIVATING" for a long time
- No new tasks starting
- Old tasks still running

**Solutions:**

1. **Force new deployment:**
   ```bash
   aws ecs update-service \
       --cluster sourcestack-cluster \
       --service sourcestack-api-service \
       --force-new-deployment \
       --region ap-south-1
   ```

2. **Check service events:**
   ```bash
   aws ecs describe-services \
       --cluster sourcestack-cluster \
       --services sourcestack-api-service \
       --region ap-south-1 \
       --query 'services[0].events[:10]' \
       --output table
   ```

3. **Check task placement:**
   - Verify subnets have available IPs
   - Check security groups allow traffic
   - Verify IAM roles are correct

---

## Quick Diagnostic Commands

### Check Service Status
```bash
aws ecs describe-services \
    --cluster sourcestack-cluster \
    --services sourcestack-api-service \
    --region ap-south-1 \
    --query 'services[0].[status,desiredCount,runningCount]' \
    --output table
```

### View Recent Events
```bash
aws ecs describe-services \
    --cluster sourcestack-cluster \
    --services sourcestack-api-service \
    --region ap-south-1 \
    --query 'services[0].events[:5]' \
    --output table
```

### Check Running Tasks
```bash
aws ecs list-tasks \
    --cluster sourcestack-cluster \
    --service-name sourcestack-api-service \
    --region ap-south-1
```

### View Logs
```bash
aws logs tail /ecs/sourcestack-api --follow --region ap-south-1
```

### Verify Image in ECR
```bash
aws ecr describe-images \
    --repository-name source-stack-api \
    --image-ids imageTag=latest \
    --region ap-south-1
```

---

## Prevention

1. **Always build for linux/amd64** (now fixed in buildspec.yml)
2. **Test locally** before deploying
3. **Monitor CloudWatch logs** during deployment
4. **Use health checks** properly
5. **Set appropriate startPeriod** for slow-starting apps
6. **Verify environment variables** are set correctly

---

## Getting Help

If issues persist:
1. Check CloudWatch logs for detailed errors
2. Review ECS service events
3. Verify all IAM roles have correct permissions
4. Test the Docker image locally
5. Check AWS Service Health Dashboard

