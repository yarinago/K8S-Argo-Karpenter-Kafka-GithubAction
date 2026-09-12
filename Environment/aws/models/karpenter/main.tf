# AWS-side prerequisites for Karpenter: the node IAM role EC2 instances it
# launches will assume, and the interruption-handling queue. No instance
# profile is created here — EC2NodeClass.spec.role (in envs/*/02-platform)
# takes the role name directly and Karpenter's controller manages the
# instance profile itself at runtime (verified against the actual
# karpenter-provider-aws example manifests, not assumed), using the
# iam:CreateInstanceProfile permissions already granted to it in
# models/iam-oidc. The Karpenter Helm release and NodePool/EC2NodeClass
# CRDs themselves live in envs/<env>/02-platform — those need the
# Kubernetes API to exist, these don't.

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.cluster_name}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
}

resource "aws_iam_role_policy_attachment" "worker_node" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Pure on-demand for this project (no spot), so interruption is mostly a
# non-event — but on-demand instances still receive AWS health/rebalance
# events, and this queue is a few cents at most, so it stays wired up
# rather than skipped.
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name          = "${var.cluster_name}-karpenter-scheduled-change"
  event_pattern = jsonencode({ source = ["aws.health"], "detail-type" = ["AWS Health Event"] })
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name          = "${var.cluster_name}-karpenter-spot-interruption"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Spot Instance Interruption Warning"] })
}

resource "aws_cloudwatch_event_rule" "rebalance" {
  name          = "${var.cluster_name}-karpenter-rebalance"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance Rebalance Recommendation"] })
}

resource "aws_cloudwatch_event_rule" "instance_state" {
  name          = "${var.cluster_name}-karpenter-instance-state"
  event_pattern = jsonencode({ source = ["aws.ec2"], "detail-type" = ["EC2 Instance State-change Notification"] })
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule = aws_cloudwatch_event_rule.scheduled_change.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "rebalance" {
  rule = aws_cloudwatch_event_rule.rebalance.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

resource "aws_cloudwatch_event_target" "instance_state" {
  rule = aws_cloudwatch_event_rule.instance_state.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}
