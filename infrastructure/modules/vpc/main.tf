# EKS can't place a control plane in these zones. Zone names map to different zones in each
# account, so they are excluded by zone ID.
data "aws_availability_zones" "available" {
  state            = "available"
  exclude_zone_ids = ["use1-az3", "usw1-az2", "cac1-az3"]

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(sort(data.aws_availability_zones.available.names), 0, min(var.az_count, length(data.aws_availability_zones.available.names)))

  # Address plan, for a /16: private /19s at the start of the range (pods take their IPs from
  # these subnets, so they need the most room), public /20s from the middle. az_count <= 4 keeps
  # the two ranges apart.
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_gateway_count = var.single_nat_gateway ? 1 : var.az_count
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # nodes must resolve the cluster's private endpoint

  tags = { Name = var.name }

  lifecycle {
    precondition {
      condition     = length(data.aws_availability_zones.available.names) >= var.az_count
      error_message = "az_count is ${var.az_count} but this region only has ${length(data.aws_availability_zones.available.names)} usable availability zones."
    }
  }
}

# Removes the rules of the VPC's default security group, so nothing can use it by accident.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

# --- Public subnets: NAT gateways and internet-facing load balancers ---------------------------
resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.public_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false # only NAT gateways and load balancers live here

  tags = {
    Name                                        = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# --- Private subnets: nodes, pods and internal load balancers ----------------------------------
resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name                                        = "${var.name}-private-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

resource "aws_eip" "nat" {
  count = local.nat_gateway_count

  domain = "vpc"

  tags = { Name = "${var.name}-nat-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = { Name = "${var.name}-${local.azs[count.index]}" }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    # With a single NAT gateway every subnet uses the first one.
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = { Name = "${var.name}-private-${local.azs[count.index]}" }
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
