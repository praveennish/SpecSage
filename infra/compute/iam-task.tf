# Three roles, because ECS separates three different questions. Conflating them is the most
# common Fargate IAM mistake and the reason tasks end up with far more access than they need.
#
#   task_execution     What the ECS AGENT may do on your behalf, BEFORE the container starts:
#                      pull the image, create log streams. The container never uses it.
#
#   ingestion_task     What the CONTAINER PROCESS may do once running. This is the one that
#                      matters — a compromised dependency runs with exactly this.
#
#   events_invoke_ecs  What EVENTBRIDGE may do: start this one task definition. Nothing more.
#
# docs/PATTERNS.md P-02 (Least Privilege).

data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# --------------------------------------------------------------------------- execution role

resource "aws_iam_role" "task_execution" {
  name               = "${var.project}-task-execution"
  description        = "ECS agent: pull the image and open log streams. Not used by the container."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --------------------------------------------------------------------------- task role

resource "aws_iam_role" "ingestion_task" {
  name               = "${var.project}-ingestion-task"
  description        = "The ingestion container. Writes the raw corpus and nothing else."
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume.json
}

data "aws_iam_policy_document" "ingestion_task" {
  # Scoped to the raw/ prefix, not the bucket. The artifacts bucket will also hold M2's
  # processed chunks and M3/M4's service snapshots; an ingestion job has no business touching
  # those, and "same bucket" is not a reason to grant access to them.
  statement {
    sid    = "WriteRawCorpus"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:GetObject", # HeadObject for the content-hash idempotency check
    ]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}/raw/*"]
  }

  # ListBucket is a BUCKET-level action, so it cannot be scoped by resource ARN the way object
  # actions can. The prefix condition is what confines it — without this the task could
  # enumerate every object in the bucket, including prefixes it cannot read.
  statement {
    sid       = "ListRawPrefixOnly"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.artifacts_bucket}"]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["raw/*", "raw/"]
    }
  }
}

resource "aws_iam_role_policy" "ingestion_task" {
  name   = "write-raw-corpus"
  role   = aws_iam_role.ingestion_task.id
  policy = data.aws_iam_policy_document.ingestion_task.json
}

# --------------------------------------------------------------------------- eventbridge role

data "aws_iam_policy_document" "events_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_invoke_ecs" {
  name               = "${var.project}-events-invoke-ecs"
  description        = "EventBridge: run the ingestion task definition. Nothing else."
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
}

data "aws_iam_policy_document" "events_invoke_ecs" {
  statement {
    sid       = "RunIngestionTaskOnly"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = ["${aws_ecs_task_definition.ingestion.arn_without_revision}:*"]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [aws_ecs_cluster.main.arn]
    }
  }

  # RunTask hands the two roles above to the task, which requires PassRole. Scoped to exactly
  # those two ARNs: without the constraint, anything able to call RunTask could pass ANY role
  # in the account to a container it controls — the classic PassRole privilege escalation.
  statement {
    sid       = "PassTaskRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.task_execution.arn, aws_iam_role.ingestion_task.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "events_invoke_ecs" {
  name   = "run-ingestion-task"
  role   = aws_iam_role.events_invoke_ecs.id
  policy = data.aws_iam_policy_document.events_invoke_ecs.json
}
