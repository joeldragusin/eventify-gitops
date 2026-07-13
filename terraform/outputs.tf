output "ecr_repository_url" {
  description = "The URL to push/pull the Eventify backend image"
  value       = aws_ecr_repository.eventify_backend.repository_url
}
