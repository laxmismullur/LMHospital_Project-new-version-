# LMHospital — Terraform AWS Infrastructure
# Provisions: VPC, Subnet, Security Group, EC2 (t2.medium), Elastic IP

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state (optional — configure your S3 bucket)
  # backend "s3" {
  #   bucket = "lm-hospital-terraform-state"
  #   key    = "prod/terraform.tfstate"
  #   region = "ap-south-1"
  # }
}

provider "aws" {
  region = var.aws_region
}

# ── Variables ─────────────────────────────────────────────────
variable "aws_region"    { default = "ap-south-1" }     # Mumbai
variable "instance_type" { default = "t2.medium" }
variable "key_pair_name" { description = "EC2 key pair name for SSH" }
variable "app_name"      { default = "lm-hospital" }

# ── VPC ───────────────────────────────────────────────────────
resource "aws_vpc" "lm_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "${var.app_name}-vpc", Project = "LMHospital" }
}

resource "aws_internet_gateway" "lm_igw" {
  vpc_id = aws_vpc.lm_vpc.id
  tags   = { Name = "${var.app_name}-igw" }
}

resource "aws_subnet" "lm_public_subnet" {
  vpc_id                  = aws_vpc.lm_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = { Name = "${var.app_name}-public-subnet" }
}

resource "aws_route_table" "lm_rt" {
  vpc_id = aws_vpc.lm_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lm_igw.id
  }
  tags = { Name = "${var.app_name}-rt" }
}

resource "aws_route_table_association" "lm_rta" {
  subnet_id      = aws_subnet.lm_public_subnet.id
  route_table_id = aws_route_table.lm_rt.id
}

# ── Security Group ────────────────────────────────────────────
resource "aws_security_group" "lm_sg" {
  name        = "${var.app_name}-sg"
  description = "LM Hospital security group"
  vpc_id      = aws_vpc.lm_vpc.id

  # HTTP
  ingress { from_port = 80   to_port = 80   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # HTTPS
  ingress { from_port = 443  to_port = 443  protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # SSH (restrict to your IP in production)
  ingress { from_port = 22   to_port = 22   protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # Spring Boot direct (dev only — remove in prod)
  ingress { from_port = 8080 to_port = 8080 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # Prometheus
  ingress { from_port = 9090 to_port = 9090 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }
  # Grafana
  ingress { from_port = 3001 to_port = 3001 protocol = "tcp" cidr_blocks = ["0.0.0.0/0"] }

  egress { from_port = 0 to_port = 0 protocol = "-1" cidr_blocks = ["0.0.0.0/0"] }

  tags = { Name = "${var.app_name}-sg" }
}

# ── EC2 Instance ──────────────────────────────────────────────
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_instance" "lm_ec2" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = var.instance_type
  key_name               = var.key_pair_name
  subnet_id              = aws_subnet.lm_public_subnet.id
  vpc_security_group_ids = [aws_security_group.lm_sg.id]

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
    encrypted   = true
  }

  # Bootstrap: install Docker, Docker Compose, pull app
  user_data = <<-EOF
    #!/bin/bash
    set -e
    yum update -y

    # Install Docker
    yum install -y docker git
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ec2-user

    # Install Docker Compose v2
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

    # App directory
    mkdir -p /opt/lm-hospital
    chown ec2-user:ec2-user /opt/lm-hospital

    echo "LMHospital EC2 bootstrap complete."
  EOF

  tags = {
    Name    = "${var.app_name}-server"
    Project = "LMHospital"
    Env     = "Production"
  }
}

# ── Elastic IP ────────────────────────────────────────────────
resource "aws_eip" "lm_eip" {
  instance = aws_instance.lm_ec2.id
  domain   = "vpc"
  tags     = { Name = "${var.app_name}-eip" }
}

# ── Outputs ───────────────────────────────────────────────────
output "ec2_public_ip"    { value = aws_eip.lm_eip.public_ip }
output "ec2_instance_id"  { value = aws_instance.lm_ec2.id }
output "app_url"          { value = "http://${aws_eip.lm_eip.public_ip}" }
output "grafana_url"      { value = "http://${aws_eip.lm_eip.public_ip}:3001" }
output "prometheus_url"   { value = "http://${aws_eip.lm_eip.public_ip}:9090" }
