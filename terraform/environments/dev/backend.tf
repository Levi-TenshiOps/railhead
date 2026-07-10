# Points this environment's terraform state at the S3 bucket/DynamoDB
# table created by terraform/bootstrap. That bootstrap config manages
# its own state locally (or you can migrate it later) since it can't
# depend on a backend it's the one creating.
terraform {
  backend "s3" {
    bucket         = "railhead-tfstate-993268717190"
    key            = "environments/dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "railhead-tfstate-lock"
    encrypt        = true
  }
}
