output "backend_url" {
  value = aws_apigatewayv2_stage.backend.invoke_url
}

output "backend_ecr_uri" {
  value = aws_ecr_repository.backend.repository_url
}

output "lambda_function_name" {
  value = aws_lambda_function.backend.function_name
}

output "aws_region" {
  value = var.aws_region
}

output "name_prefix" {
  value = var.name_prefix
}

