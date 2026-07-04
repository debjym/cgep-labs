# outputs.tf
output "bucket_arn"     { value = aws_s3_bucket.primary.arn }
output "bucket_name"    { value = aws_s3_bucket.primary.id }
output "log_bucket_arn" { value = aws_s3_bucket.log.arn }

# encryption_algorithm output intentionally removed for Lab 3.4 Step 8
# along with its source resource (deliberately broken plan).