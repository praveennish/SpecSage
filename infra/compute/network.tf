# Network for the Fargate batch tasks. Lambda needs none of this — it runs outside a VPC
# deliberately (attaching Lambda to a VPC adds ENI cold-start latency and, without a NAT
# Gateway, removes the internet access Bedrock calls need at M3).
#
# A DEDICATED VPC rather than the account's default one. The default VPC exists and has public
# subnets, so this is ~8 resources that could have been zero. Three reasons it is worth it:
#
#   1. This account is not pristine — it carries pre-existing resources from other work. A
#      dedicated VPC means the ingestion task's security group and routing are ours alone.
#   2. It is free. Cost here is NAT Gateways and endpoints, and there are none (D-007).
#   3. M10 moves workloads into private subnets. Starting from our own VPC makes that a
#      modification; starting from the default VPC would make it a migration.
#
# docs/PATTERNS.md P-02 (Least Privilege) applied to the network rather than to IAM.

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required for ECR pulls to resolve

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project}-igw" }
}

# Two AZs. One would work and cost the same; two means a task can still launch when an AZ is
# having a bad day, which for a batch job is the difference between "retry tomorrow" and
# "nobody noticed".
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.project}-public-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# NO INBOUND RULES AT ALL.
#
# The ingestion task initiates connections outward — GitHub, raspberrypi.com, S3 — and nothing
# ever connects to it. An empty ingress block is not an oversight; it is the entire security
# posture that makes running in a public subnet acceptable (D-007). A public subnet with
# assign_public_ip gives the task a routable address, and this security group is what ensures
# nothing on the internet can use it.
resource "aws_security_group" "task" {
  name        = "${var.project}-task"
  description = "Egress-only. Batch tasks initiate connections; nothing connects to them."
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound - the task fetches from arbitrary document hosts"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-task" }

  lifecycle {
    create_before_destroy = true
  }
}
