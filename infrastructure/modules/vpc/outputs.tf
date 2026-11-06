output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "availability_zones" {
  description = "Availability zones in use."
  value       = local.azs
}

output "private_subnet_ids" {
  description = "IDs of the private subnets."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets."
  value       = aws_subnet.public[*].id
}

output "nat_gateway_count" {
  description = "Number of NAT gateways created."
  value       = length(aws_nat_gateway.this)
}
