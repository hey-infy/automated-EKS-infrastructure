resource "aws_vpc" "q0" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = {
    Name = "Q0-VPC"
    Project = "Q0"
  }
}

resource "aws_internet_gateway" "q0" {
  vpc_id = aws_vpc.q0.id
  tags = {
    Name = "Q0-Internet-Gateway"
    Project = "Q0"
  }
}

resource "aws_subnet" "public" {
  count = 2
  vpc_id            = aws_vpc.q0.id
  cidr_block        = element(var.public_subnets, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags = {
    Name                                  = "Q0-Public-Subnet-${count.index + 1}"
    Project                               = "Q0"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"              = "1"
  }
}

resource "aws_subnet" "private" {
  count = 2
  vpc_id            = aws_vpc.q0.id
  cidr_block        = element(var.private_subnets, count.index)
  availability_zone = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name                                         = "Q0-Private-Subnet-${count.index + 1}"
    Project                                      = "Q0"
    "kubernetes.io/cluster/${var.cluster_name}"  = "shared"
    "kubernetes.io/role/internal-elb"            = "1"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "Q0-NAT-EIP"
    Project = "Q0"
  }
}

resource "aws_nat_gateway" "q0" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags = {
    Name = "Q0-NAT-Gateway"
    Project = "Q0"
  }
  depends_on = [aws_internet_gateway.q0]
}

resource "aws_route_table" "public" {
  count  = 2
  vpc_id = aws_vpc.q0.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.q0.id
  }
  tags = {
    Name = "Q0-Public-Route-Table-${count.index + 1}"
    Project = "Q0"
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[count.index].id
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.q0.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.q0.id
  }
  tags = {
    Name = "Q0-Private-Route-Table-${count.index + 1}"
    Project = "Q0"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

data "aws_availability_zones" "available" {
  state = "available"
}
