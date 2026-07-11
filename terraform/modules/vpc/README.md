# vpc

Creates the networking foundation for an environment: a VPC with 2 public and 2 private subnets spread across 2 AZs, an Internet Gateway, and a single NAT Gateway shared by both private subnets. Public subnets auto-assign public IPs; private subnets route outbound traffic through the NAT Gateway. Subnets are pre-tagged for EKS/load-balancer auto-discovery (`kubernetes.io/role/elb`, `kubernetes.io/role/internal-elb`, `kubernetes.io/cluster/<name>`) even though no cluster exists yet.

**Inputs:** `cluster_name` (default `railhead-dev`, used in resource names and the EKS discovery tags), `vpc_cidr` (default `10.0.0.0/16`).

**Outputs:** `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `nat_gateway_id`.

**Cost note:** the NAT Gateway bills hourly plus per-GB data processing — this is the one component in this module that isn't free to leave running.
