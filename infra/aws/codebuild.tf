data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "build_artifacts" {
  bucket        = "${var.name_prefix}-build-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.name_prefix}-build" }
}

resource "aws_s3_bucket_lifecycle_configuration" "build_artifacts" {
  bucket = aws_s3_bucket.build_artifacts.id
  rule {
    id     = "expire-old-sources"
    status = "Enabled"
    expiration { days = 7 }
    filter {}
  }
}

resource "aws_iam_role" "codebuild" {
  name = "${var.name_prefix}-codebuild"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild" {
  name = "${var.name_prefix}-codebuild"
  role = aws_iam_role.codebuild.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = [
          aws_ecr_repository.backend.arn,
          aws_ecr_repository.frontend.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.build_artifacts.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "*"
      }
    ]
  })
}

locals {
  buildspec = <<-BUILDSPEC
    version: 0.2
    phases:
      pre_build:
        commands:
          - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $REPOSITORY_URI
      build:
        commands:
          - docker build --platform linux/amd64 $BUILD_ARGS -t $REPOSITORY_URI:$IMAGE_TAG .
      post_build:
        commands:
          - docker push $REPOSITORY_URI:$IMAGE_TAG
  BUILDSPEC
}

resource "aws_codebuild_project" "backend" {
  name          = "${var.name_prefix}-backend-build"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.build_artifacts.bucket}/backend-source.zip"
    buildspec = local.buildspec
  }

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.backend.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
    environment_variable {
      name  = "BUILD_ARGS"
      value = ""
    }
  }

  tags = { Name = "${var.name_prefix}-backend-build" }
}

resource "aws_codebuild_project" "frontend" {
  name          = "${var.name_prefix}-frontend-build"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  source {
    type      = "S3"
    location  = "${aws_s3_bucket.build_artifacts.bucket}/frontend-source.zip"
    buildspec = local.buildspec
  }

  artifacts { type = "NO_ARTIFACTS" }

  environment {
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/standard:7.0"
    type            = "LINUX_CONTAINER"
    privileged_mode = true

    environment_variable {
      name  = "REPOSITORY_URI"
      value = aws_ecr_repository.frontend.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
    environment_variable {
      name  = "BUILD_ARGS"
      value = ""
    }
  }

  tags = { Name = "${var.name_prefix}-frontend-build" }
}
