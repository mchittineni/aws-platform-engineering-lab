output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC IPv4 CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered by availability zone"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered by availability zone"
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones the subnets were placed in"
  value       = var.availability_zones
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs. Needed to alarm on port allocation errors and dropped packets."
  value       = aws_nat_gateway.this[*].id
}

output "nat_gateway_public_ips" {
  description = "Public IP addresses used for egress. Useful for third party allow lists."
  value       = aws_eip.nat[*].public_ip
}

output "vpc_endpoint_security_group_id" {
  description = "Security group protecting the interface VPC endpoints"
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}
