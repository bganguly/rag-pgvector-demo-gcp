resource "aws_s3_bucket" "build_artifacts" {
  bucket        = "${var.name_prefix}-build-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = { Name = "${var.name_prefix}-build" }
}
