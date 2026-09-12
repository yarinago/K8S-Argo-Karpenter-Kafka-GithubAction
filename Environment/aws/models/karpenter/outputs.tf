output "node_iam_role_name" {
  value = aws_iam_role.karpenter_node.name
}

output "node_iam_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}

output "interruption_queue_name" {
  value = aws_sqs_queue.karpenter_interruption.name
}
