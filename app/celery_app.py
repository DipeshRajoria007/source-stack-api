# sourcestack-api/app/celery_app.py
import os
from celery import Celery
from dotenv import load_dotenv

load_dotenv()

# Redis connection URL
REDIS_URL = os.getenv("REDIS_URL", "redis://localhost:6379/0")

# Create Celery app
celery_app = Celery(
    "sourcestack_api",
    broker=REDIS_URL,
    backend=REDIS_URL,
    include=["app.tasks"]
)

# Celery configuration
celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    task_track_started=True,
    task_time_limit=3600,  # 1 hour max per task
    task_soft_time_limit=3300,  # 55 minutes soft limit
    worker_prefetch_multiplier=1,  # Prefetch only 1 task at a time for better distribution
    worker_max_tasks_per_child=50,  # Restart worker after 50 tasks to prevent memory leaks
    task_acks_late=True,  # Acknowledge tasks only after completion
    task_reject_on_worker_lost=True,  # Re-queue tasks if worker dies
)

