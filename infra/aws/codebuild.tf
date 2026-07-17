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

locals {
  buildspec = <<-BUILDSPEC
    version: 0.2
    phases:
      pre_build:
        commands:
          - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $REPOSITORY_URI
      build:
        commands:
          - docker build --platform linux/amd64 -t $REPOSITORY_URI:$IMAGE_TAG .
      post_build:
        commands:
          - docker push $REPOSITORY_URI:$IMAGE_TAG
          - docker tag $REPOSITORY_URI:$IMAGE_TAG $REPOSITORY_URI:latest
          - docker push $REPOSITORY_URI:latest
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
  }

  tags = { Name = "${var.name_prefix}-backend-build" }
}
