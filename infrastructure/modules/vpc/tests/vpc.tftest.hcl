# Unit tests for the vpc module. The AWS provider is mocked: no credentials needed, nothing is
# created. Run from modules/vpc: terraform init && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
    }
  }
}

variables {
  name         = "test"
  cluster_name = "test-cluster"
  vpc_cidr     = "10.0.0.0/16"
}

run "subnets_do_not_overlap" {
  command = plan

  variables {
    az_count = 4
  }

  assert {
    condition     = local.private_subnet_cidrs == ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19", "10.0.96.0/19"]
    error_message = "Private subnets must be /19s from the start of the range."
  }

  assert {
    condition     = local.public_subnet_cidrs == ["10.0.128.0/20", "10.0.144.0/20", "10.0.160.0/20", "10.0.176.0/20"]
    error_message = "Public subnets must be /20s from the middle of the range."
  }
}

run "subnets_are_tagged_for_load_balancers" {
  command = plan

  assert {
    condition     = alltrue([for s in aws_subnet.public : s.tags["kubernetes.io/role/elb"] == "1" && s.tags["kubernetes.io/cluster/test-cluster"] == "shared"])
    error_message = "Public subnets must be discoverable for internet-facing load balancers."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.private : s.tags["kubernetes.io/role/internal-elb"] == "1" && s.tags["kubernetes.io/cluster/test-cluster"] == "shared"])
    error_message = "Private subnets must be discoverable for internal load balancers."
  }

  assert {
    condition     = alltrue([for s in aws_subnet.public : !s.map_public_ip_on_launch])
    error_message = "Instances in public subnets must not get public IPs automatically."
  }
}

run "subnets_span_distinct_zones" {
  command = plan

  variables {
    az_count = 3
  }

  assert {
    condition     = length(toset([for s in aws_subnet.private : s.availability_zone])) == 3
    error_message = "Each private subnet must be in its own availability zone."
  }
}

run "single_nat_gateway" {
  command = plan

  variables {
    az_count           = 3
    single_nat_gateway = true
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "single_nat_gateway must create exactly one NAT gateway."
  }

  assert {
    condition     = length(aws_route_table.private) == 3
    error_message = "Each private subnet keeps its own route table."
  }
}

run "nat_gateway_per_zone" {
  command = plan

  variables {
    az_count           = 3
    single_nat_gateway = false
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 3 && length(aws_eip.nat) == 3
    error_message = "Without single_nat_gateway each zone needs its own NAT gateway."
  }
}

run "dns_is_enabled" {
  command = plan

  assert {
    condition     = aws_vpc.this.enable_dns_hostnames && aws_vpc.this.enable_dns_support
    error_message = "Nodes need DNS to resolve the private cluster endpoint."
  }
}

run "rejects_one_zone" {
  command = plan

  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "rejects_small_vpc" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/24"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_more_zones_than_the_region_has" {
  command = plan

  variables {
    az_count = 3
  }

  override_data {
    target = data.aws_availability_zones.available
    values = {
      names = ["us-east-1a", "us-east-1b"]
    }
  }

  expect_failures = [aws_vpc.this]
}
