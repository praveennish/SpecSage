# M1 ingestion — a one-off ECS Fargate task, not a service.
#
# The distinction matters. A *service* maintains a desired count and bills continuously; a
# *task* runs to completion and bills per second. Ingestion takes ~20 seconds and runs
# occasionally, so a 20-second run costs roughly $0.0002. That is the D-020 split working:
# request/response on Lambda, batch on Fargate, chosen by workload shape rather than habit.

resource "aws_ecs_cluster" "main" {
  name = var.project

  # A cluster is a namespace, not compute. It costs nothing whether or not anything runs in it.
  setting {
    name  = "containerInsights"
    value = "disabled" # paid feature; nothing here needs per-container metrics yet
  }
}

resource "aws_cloudwatch_log_group" "ingestion" {
  name              = "/ecs/${var.project}-ingestion"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "ingestion" {
  family                   = "${var.project}-ingestion"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # 0.5 vCPU / 1 GB. The job is I/O bound — it downloads ~7 MB and hashes it — so CPU is not
  # the constraint. 1 GB is headroom for pypdf holding a 5.5 MB PDF's page tree in memory.
  cpu    = "512"
  memory = "1024"

  runtime_platform {
    cpu_architecture        = "ARM64" # must match the image; Graviton is ~20% cheaper
    operating_system_family = "LINUX"
  }

  execution_role_arn = aws_iam_role.task_execution.arn
  task_role_arn      = aws_iam_role.ingestion_task.arn

  container_definitions = jsonencode([
    {
      name      = "ingestion"
      image     = local.image_uri
      essential = true

      # THE SAME IMAGE THE API RUNS. Only the command differs — the Dockerfile's CMD starts
      # uvicorn for Lambda; this overrides it. One artifact, one SHA, two entrypoints.
      command = [
        "python", "-m", "ingestion",
        "--bucket", var.artifacts_bucket,
        "--verbose",
      ]

      environment = [
        { name = "AWS_REGION", value = var.aws_region },
        { name = "GIT_SHA", value = var.image_tag },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.ingestion.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "ingestion"
        }
      }
    }
  ])

  depends_on = [aws_cloudwatch_log_group.ingestion]
}

# --------------------------------------------------------------------------- trigger
#
# On-demand only for M1. A schedule matters at M12, when a stale corpus becomes a real
# problem; right now re-running is a deliberate act. The rule exists disabled so the wiring
# is proven and enabling it later is a one-line change rather than new infrastructure.

resource "aws_cloudwatch_event_rule" "ingestion_schedule" {
  name                = "${var.project}-ingestion"
  description         = "Scheduled corpus refresh. Disabled until M12 — see ecs.tf."
  schedule_expression = "rate(7 days)"
  state               = "DISABLED"
}

resource "aws_cloudwatch_event_target" "ingestion" {
  rule     = aws_cloudwatch_event_rule.ingestion_schedule.name
  arn      = aws_ecs_cluster.main.arn
  role_arn = aws_iam_role.events_invoke_ecs.arn

  ecs_target {
    task_definition_arn = aws_ecs_task_definition.ingestion.arn
    launch_type         = "FARGATE"
    task_count          = 1

    network_configuration {
      subnets          = aws_subnet.public[*].id
      security_groups  = [aws_security_group.task.id]
      assign_public_ip = true # no NAT Gateway — see network.tf and D-007
    }
  }
}
