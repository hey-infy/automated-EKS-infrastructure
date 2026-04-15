variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "cluster_name" {
  type    = string
  default = "q0-cluster"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.10.0.0/24", "10.10.1.0/24"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.10.100.0/24", "10.10.101.0/24"]
}

variable "node_group_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "desired_capacity" {
  type    = number
  default = 2
}

variable "max_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type    = number
  default = 2
}

variable "istio_ingress_hostname" {
  type        = string
  description = "Istio ingress load balancer hostname used as the CloudFront origin."
  default     = ""
}
