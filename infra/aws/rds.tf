resource "aws_db_instance" "pg" {
  identifier             = "${var.name_prefix}-db"
  engine                 = "postgres"
  engine_version         = "16"
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  storage_type           = "gp3"
  db_name                = "ragdb"
  username               = "raguser"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.pg.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  backup_retention_period = 0
  skip_final_snapshot    = true
  deletion_protection    = false
  apply_immediately      = true

  tags = { Name = "${var.name_prefix}-db" }
}
