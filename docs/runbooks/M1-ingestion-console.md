# M1 — Ingestion: AWS console walkthrough

Everything `infra/compute/{network,ecs,iam-task}.tf` creates, and how to run the job by hand
through the console.

**Read this before applying.** You do not have to click through it — the point is to know what
the apply creates, where each setting lives in the UI, and where the console default differs
from what the Terraform sets.

| Resource | Terraform | Console location |
|---|---|---|
| VPC, subnets, IGW, route table | `network.tf` | VPC → Your VPCs |
| Security group (egress-only) | `network.tf` | VPC → Security groups |
| ECS cluster | `ecs.tf` | ECS → Clusters |
| Task definition | `ecs.tf` | ECS → Task definitions |
| Log group | `ecs.tf` | CloudWatch → Log groups |
| 3 IAM roles | `iam-task.tf` | IAM → Roles |
| EventBridge rule (disabled) | `ecs.tf` | EventBridge → Rules |

**Plan: 19 to add, 1 to change** (the Lambda image tag), **0 to destroy.**

---

## Part 0 — What this job actually does

```
ECS Fargate task (runs ~20s, then exits)
  python -m ingestion --bucket specsage-artifacts-941500193593
        │
        ├─ 1. licence preflight   all 4 sources, BEFORE any download
        ├─ 2. fetch               GitHub releases, GitHub tree, direct PDF
        ├─ 3. page ceiling        halt if > 1500 pages
        ├─ 4. upload              s3://…/raw/<source>/<file>, skip if SHA matches
        └─ 5. manifest            s3://…/raw/manifest.yaml, written LAST
```

Verified locally: **30 files, 7.2 MB, 1,136 pages, 4 sources.**

---

## Part 1 — Network

**Terraform:** `network.tf` · **Console:** VPC → Your VPCs → Create VPC

| Field | Set to | Console default | Why it differs |
|---|---|---|---|
| Resources to create | VPC only (we build the rest explicitly) | "VPC and more" | The wizard creates NAT Gateways by default — see the warning below |
| IPv4 CIDR | `10.20.0.0/16` | — | Room to grow; costs nothing |
| **DNS hostnames** | **Enable** | Disabled | ⚠️ Without it, ECR image pulls fail to resolve. The error looks like a network fault, not a DNS setting. |
| DNS resolution | Enable | Enabled | Same |

> ### ⚠️ The console wizard will try to charge you $65/month
>
> "VPC and more" defaults to creating **NAT Gateways in each AZ** — about $32.40/month each,
> plus data processing. For two AZs that is ~$65/month against a project whose entire current
> spend is $0.02.
>
> This project has no private subnets and needs no NAT ([D-007](../DECISION-LOG.md)). The
> ingestion task runs in a **public** subnet with `assign_public_ip = true`, and its security
> group has **no inbound rules at all**. That combination gives outbound internet access with
> no inbound path — which is the property that actually matters.
>
> If you build this by hand, set **NAT gateways: None** on that wizard page. It is the single
> most expensive default in the AWS console.

Then, per subnet — VPC → Subnets → Create subnet:

| Field | Value |
|---|---|
| CIDR | `10.20.0.0/24` and `10.20.1.0/24` |
| AZ | two different ones |
| **Auto-assign public IPv4** | **Enable** (Subnet → Actions → Edit subnet settings) |

Auto-assign is off by default and is not offered during creation. A Fargate task in a subnet
without it, with `assign_public_ip = ENABLED`, still gets an address — but the subnet setting
is what makes the behaviour consistent if anything else ever launches there.

Then an Internet Gateway (VPC → Internet gateways → Create, then **Attach to VPC**) and a
route table with `0.0.0.0/0 → igw-…` associated to both subnets.

### Security group

VPC → Security groups → Create security group.

| Field | Value |
|---|---|
| Inbound rules | **none — delete any the console pre-fills** |
| Outbound | All traffic, `0.0.0.0/0` |

**An empty inbound list is the entire security posture here.** The console does not pre-fill
inbound rules for a new SG, but it does for several wizards — check.

---

## Part 2 — The three IAM roles

**Terraform:** `iam-task.tf` · **Console:** IAM → Roles → Create role → AWS service → Elastic Container Service

ECS separates three questions, and conflating them is the most common Fargate IAM mistake:

| Role | Answers | Used by |
|---|---|---|
| `specsage-task-execution` | What may the ECS **agent** do *before* the container starts? | pull image, create log streams |
| `specsage-ingestion-task` | What may the **container process** do once running? | **the one that matters** |
| `specsage-events-invoke-ecs` | What may **EventBridge** do? | start this one task definition |

### 2a — Task execution role

Trusted entity **Elastic Container Service Task** → attach `AmazonECSTaskExecutionRolePolicy`.
Name it `specsage-task-execution`. That managed policy is exactly right here and needs no
customisation — it grants ECR pull and CloudWatch Logs write, nothing else.

**The container never uses this role.** If you put S3 permissions here (a very common mistake),
the container still cannot reach S3 — and you will spend an hour wondering why.

### 2b — Ingestion task role

Same trusted entity. Then an inline policy — this is the one worth reading:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteRawCorpus",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectTagging", "s3:GetObject"],
      "Resource": "arn:aws:s3:::specsage-artifacts-941500193593/raw/*"
    },
    {
      "Sid": "ListRawPrefixOnly",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::specsage-artifacts-941500193593",
      "Condition": { "StringLike": { "s3:prefix": ["raw/*", "raw/"] } }
    }
  ]
}
```

Two things worth understanding rather than copying:

**Scoped to `raw/*`, not the bucket.** The artifacts bucket will also hold M2's processed
chunks and M3/M4's service snapshots. An ingestion job has no business touching those, and
"same bucket" is not a reason to grant access.

**`s3:ListBucket` is a bucket-level action** — its `Resource` is the *bucket* ARN, not an
object path, so it cannot be narrowed the way `PutObject` can. The `s3:prefix` **condition** is
what confines it. Without that condition the task could enumerate every object in the bucket,
including prefixes it cannot read. This asymmetry between bucket-level and object-level actions
catches people constantly.

### 2c — EventBridge role

Trusted entity **EventBridge**. Inline policy allowing `ecs:RunTask` on the task definition,
plus:

```json
{
  "Sid": "PassTaskRoles",
  "Effect": "Allow",
  "Action": "iam:PassRole",
  "Resource": [
    "arn:aws:iam::941500193593:role/specsage-task-execution",
    "arn:aws:iam::941500193593:role/specsage-ingestion-task"
  ],
  "Condition": { "StringEquals": { "iam:PassedToService": "ecs-tasks.amazonaws.com" } }
}
```

> **`iam:PassRole` is where Fargate IAM goes wrong.** `RunTask` hands the two roles above to
> the task, which requires `PassRole`. Grant it with `"Resource": "*"` — which plenty of
> tutorials do — and anything able to call `RunTask` can pass **any role in the account** to a
> container it controls. That is a full privilege escalation from "can start a batch job" to
> "can be the admin role". Both the resource list and the `PassedToService` condition are
> load-bearing.

---

## Part 3 — Cluster and task definition

**ECS → Clusters → Create cluster**

| Field | Value | Note |
|---|---|---|
| Name | `specsage` | |
| Infrastructure | AWS Fargate | |
| Container Insights | **off** | Paid feature, on by default in some console flows. Nothing here needs per-container metrics yet. |

A cluster is a **namespace, not compute**. It costs nothing whether or not anything runs in it.

**ECS → Task definitions → Create new task definition**

| Field | Value | Why |
|---|---|---|
| Family | `specsage-ingestion` | |
| Launch type | Fargate | |
| OS/Architecture | **Linux/ARM64** | Must match the image, or the task fails with an exec-format error that never mentions architecture |
| CPU / Memory | 0.5 vCPU / 1 GB | I/O bound job; 1 GB is headroom for pypdf holding a 5.5 MB page tree |
| Task role | `specsage-ingestion-task` | the container |
| Task execution role | `specsage-task-execution` | the agent |

Container:

| Field | Value |
|---|---|
| Name | `ingestion` |
| Image URI | `941500193593.dkr.ecr.us-east-1.amazonaws.com/specsage-api:<sha>` |
| **Command** | `python,-m,ingestion,--bucket,specsage-artifacts-941500193593,--verbose` |
| Log driver | awslogs → `/ecs/specsage-ingestion` |

**Note the image is `specsage-api`.** One image, two entrypoints: the Dockerfile's `CMD` starts
uvicorn for Lambda; this task overrides `command`. Two images would mean two build pipelines,
two ECR repos, two lifecycle policies, and two chances for a SHA to mean different things in
different places.

In the console the Command field is **comma-separated, not space-separated**. Entering
`python -m ingestion` as one string makes ECS look for an executable literally named
`python -m ingestion`.

---

## Part 4 — Running it by hand

**ECS → Clusters → `specsage` → Tasks → Run new task**

| Field | Value |
|---|---|
| Launch type | Fargate |
| Task definition | `specsage-ingestion`, latest revision |
| VPC | `specsage-vpc` |
| Subnets | both `specsage-public-*` |
| Security group | `specsage-task` |
| **Public IP** | **Turned on** |

⚠️ **Public IP defaults to OFF in the Run-task dialog.** With no NAT Gateway and no public IP,
the task has no route to the internet at all. It will sit in `PROVISIONING`, fail to pull the
image, and stop with `CannotPullContainerError` — which reads like an ECR permissions problem
and is not.

Or from the repo root:

```bash
make ingest
```

That target reads the subnet IDs, security group, cluster, and task definition from Terraform
outputs, starts the task, waits for it to stop, prints the logs, and **exits non-zero if the
container did**.

> **Why a Make target rather than a command to paste.** The AWS CLI shorthand parser rejects
> newlines and spaces inside `awsvpcConfiguration={...}`, so a nicely-formatted multi-line
> version of this command does not work — it has to be assembled on one line. An earlier draft
> of this runbook had exactly that bug. A command that has to be exactly right is a command
> that belongs somewhere it can be tested, not in a document someone copies from.

If you do want the raw call — note it is a single line:

```bash
export AWS_PROFILE=specsage
SUBNETS=$(terraform -chdir=infra/compute output -raw subnet_ids)
SG=$(terraform -chdir=infra/compute output -raw task_security_group_id)

aws ecs run-task --cluster specsage --task-definition specsage-ingestion \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=ENABLED}"
```

### Watching it

**CloudWatch → Log groups → `/ecs/specsage-ingestion`** — or tail it:

```bash
aws logs tail /ecs/specsage-ingestion --follow
```

Expected, in order:

```
licence preflight passed for 4 source(s)
fetched riscv-isa-manual/riscv-spec.pdf (5542499 bytes, 906 pages)
fetched devicetree-spec/devicetree-specification-v0.4.pdf (422295 bytes, 64 pages)
fetched bcm2711-peripherals/bcm2711-peripherals.pdf (1329416 bytes, 166 pages)
page ceiling ok: 1136 / 1500
corpus: 30 file(s), 7.2 MB, 1136 pages across 4 source(s)
s3://specsage-artifacts-941500193593/raw/ — 30 uploaded, 0 unchanged, manifest written
```

### Verifying

```bash
aws s3 ls s3://specsage-artifacts-941500193593/raw/ --recursive --human-readable --summarize
aws s3 cp s3://specsage-artifacts-941500193593/raw/manifest.yaml - | head -30
```

**Run it twice.** The second run should report `0 uploaded, 30 unchanged` — each object stores
its SHA256 as user metadata, and an upload is skipped when the remote hash matches. That means
a no-op run creates zero new object versions, so **any** new version in the bucket means an
upstream document genuinely changed. That signal is the point.

---

## Part 5 — The schedule

**Terraform:** `ecs.tf` · **Console:** EventBridge → Rules → `specsage-ingestion`

Created **DISABLED** on purpose. On-demand is enough for M1; a stale corpus only becomes a real
problem at M12. The rule exists so the wiring is proven and enabling it later is a one-line
change rather than new infrastructure.

To enable by hand: EventBridge → Rules → select → **Enable**.
In Terraform: `state = "ENABLED"` in `ecs.tf`.

---

## Cost

| Resource | Billing | $/mo |
|---|---|---|
| VPC, subnets, IGW, route table, SG | free | $0.00 |
| ECS cluster | free (a namespace) | $0.00 |
| EventBridge rule | free tier | $0.00 |
| CloudWatch Logs | per GB, 7-day retention | ~$0.05 |
| S3 storage (7.2 MB) | per GB | ~$0.01 |
| **Fargate task** | **per second while running** | **~$0.0002 per 20s run** |
| **Total** | | **~$0.06/mo** |

There is no NAT Gateway. That single omission is worth more than everything in this table
combined — see the warning in Part 1.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `CannotPullContainerError` | Public IP off and no NAT — the task has no route out | Turn on public IP (Part 4) |
| `exec format error` / task exits immediately | Task definition says X86_64, image is arm64 | Set OS/Architecture to Linux/ARM64 |
| Task starts, then `AccessDenied` on S3 | S3 permissions on the *execution* role instead of the *task* role | Part 2b — the container uses the task role |
| `ResourceInitializationError` … logs | Log group does not exist yet | Terraform has `depends_on`; by hand, create it first |
| Image pull times out but public IP is on | DNS hostnames disabled on the VPC | Part 1 — enable DNS hostnames |
| Job halts: `corpus is N pages, ceiling is 1500` | An upstream document grew | Deliberate. Trim `sources.py` or raise `PAGE_CEILING` knowing it costs M3/M4 |
| `licence preflight failed` | A source in `sources.py` lacks a resolvable licence | Working as designed — nothing was downloaded |
