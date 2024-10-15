provider "aws" {
  region = "us-west-2" # Change to your preferred region
}

# Create a VPC
resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "eks-vpc"
  }
}

# Create subnets
resource "aws_subnet" "eks_subnet" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["us-west-2a", "us-west-2b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "eks-subnet-${count.index + 1}"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.eks_vpc.id
  tags = {
    Name = "eks-igw"
  }
}

# Create route table
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.eks_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "eks-route-table"
  }
}

# Associate route table with subnets
resource "aws_route_table_association" "rta" {
  count      = 2
  subnet_id  = aws_subnet.eks_subnet[count.index].id
  route_table_id = aws_route_table.rt.id
}

# Create security group for ALB and EC2 instances
resource "aws_security_group" "eks_sg" {
  vpc_id = aws_vpc.eks_vpc.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "eks-security-group"
  }
}

# Create IAM role for EKS Cluster
resource "aws_iam_role" "eks_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
      }
    ]
  })
}

# Attach the required policy for EKS Cluster role
resource "aws_iam_role_policy_attachment" "eks_role_policy" {
  role       = aws_iam_role.eks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Create an EKS Cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = "my-eks-cluster"
  role_arn = aws_iam_role.eks_role.arn
  vpc_config {
    subnet_ids = aws_subnet.eks_subnet[*].id
  }
}

# IAM role for worker nodes
resource "aws_iam_role" "eks_worker_role" {
  name = "eks-worker-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach policies to worker nodes role
resource "aws_iam_role_policy_attachment" "eks_worker_role_policy" {
  role       = aws_iam_role.eks_worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_worker_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# Create IAM instance profile for worker nodes
resource "aws_iam_instance_profile" "eks_instance_profile" {
  name = "eks-instance-profile"
  role = aws_iam_role.eks_worker_role.name
}

# Create Launch Template for worker nodes
resource "aws_launch_template" "eks_worker_lt" {
  name          = "eks-worker-lt"
  instance_type = "t3.medium"
  iam_instance_profile {
    name = aws_iam_instance_profile.eks_instance_profile.name
  }
  image_id      = "ami-0a54c984b9f908c81"  # Amazon EKS optimized AMI
  key_name      = "ekstf"  # Change this to your SSH key pair name

  vpc_security_group_ids = [aws_security_group.eks_sg.id]

  user_data = base64encode(<<-EOT
    #!/bin/bash
    /etc/eks/bootstrap.sh ${aws_eks_cluster.eks_cluster.name}
    EOT
  )
  
  tags = {
    Name = "eks-worker-template"
  }
}

# Create Auto Scaling Group for worker nodes using Launch Template
resource "aws_autoscaling_group" "eks_asg" {
  desired_capacity     = 2
  max_size             = 3
  min_size             = 1
  vpc_zone_identifier  = aws_subnet.eks_subnet[*].id
  launch_template {
    id      = aws_launch_template.eks_worker_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "eks-worker"
    propagate_at_launch = true
  }
}

# Create an Application Load Balancer (ALB)
resource "aws_lb" "app_lb" {
  name               = "eks-app-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.eks_sg.id]
  subnets            = aws_subnet.eks_subnet[*].id
}

# Create target group for the ALB
resource "aws_lb_target_group" "app_tg" {
  name        = "eks-app-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.eks_vpc.id
  target_type = "instance"
}

# Create listener for the ALB
resource "aws_lb_listener" "app_lb_listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app_tg.arn
  }
}

# Attach worker nodes to the target group
resource "aws_autoscaling_attachment" "asg_attachment" {
  autoscaling_group_name = aws_autoscaling_group.eks_asg.name
  lb_target_group_arn    = aws_lb_target_group.app_tg.arn
}

# Outputs
output "eks_cluster_endpoint" {
  value = aws_eks_cluster.eks_cluster.endpoint
}

output "alb_dns_name" {
  value = aws_lb.app_lb.dns_name
}

