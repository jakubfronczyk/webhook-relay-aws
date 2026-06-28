# aws-terraform-ecs-setup

Production-grade AWS infrastructure for a containerised API platform — built with Terraform, structured with modules, and hardened against the most common IaC security mistakes.

The starting point was a functional but insecure monolithic `main.tf`: public database, hardcoded passwords, wildcard security groups, no load balancer, no auto-scaling. The goal was to turn it into something you'd actually run in production.

---

## The problems with the original code

| Issue | Risk | Fix |
|---|---|---|
| `password = "password123"` in plain text | Any git clone leaks credentials | AWS Secrets Manager |
| `publicly_accessible = true` on RDS | Database port open to the internet | Move to private subnet |
| Security group allows all ports (`0–65535`) from `0.0.0.0/0` | Every port on every container exposed globally | Least-privilege SGs: ALB → ECS → RDS chain |
| DB security group: `cidr_blocks = ["0.0.0.0/0"]` on port 5432 | Postgres open to the internet | SG source reference — only ECS can reach RDS |
| ECS and RDS in public subnets | Direct internet exposure for compute and data | Private subnets + NAT Gateway |
| Single ECS task, no load balancer | Single point of failure | ALB + target group + health checks |
| `desired_count = 1`, no auto-scaling | No resilience under load | ECS auto-scaling policy on CPU |
| `retention_in_days = 7` | Logs gone before any incident investigation | 30 days minimum |
| Everything in one flat `main.tf` | Unreadable, untestable, impossible to reuse | Four Terraform modules |

---

## Architecture

```
                          Internet
                              │
                    ┌─────────▼──────────┐
                    │  Application Load   │
                    │  Balancer (public)  │
                    └─────────┬──────────┘
                              │ port 80 / 443
              ┌───────────────┼───────────────┐
              │               │               │
       AZ-1 (public)   AZ-2 (public)     NAT Gateway
              │               │               │
    ──────────┼───────────────┼───────────────┼── private boundary ──
              │               │               │
       ┌──────▼──────┐ ┌──────▼──────┐        │ (outbound only)
       │ ECS Fargate │ │ ECS Fargate │◄────────┘
       │  container  │ │  container  │
       └──────┬──────┘ └──────┬──────┘
              │               │  port 5432 only (from ECS SG)
       ┌──────▼───────────────▼──────┐
       │     RDS PostgreSQL          │
       │     (private subnet,        │
       │      multi-AZ subnet group) │
       └─────────────────────────────┘
```

Traffic enters at the ALB — the only public-facing resource. ECS containers live in private subnets and are unreachable from the internet directly. RDS only accepts connections from the ECS security group, not from any CIDR range.

---

## What was built

### Networking module
- VPC with DNS enabled
- 2 public subnets across 2 AZs (ALB only)
- 2 private subnets across 2 AZs (ECS + RDS)
- Internet Gateway for public subnets
- NAT Gateway + Elastic IP for private subnet outbound traffic
- Separate route tables: public → IGW, private → NAT

### Security module
- ALB security group: accepts `80`/`443` from `0.0.0.0/0`
- ECS security group: accepts traffic **only from the ALB security group** (not a CIDR range)
- Database security group: accepts `5432` **only from the ECS security group**

This is the security group chain pattern — each layer only trusts the layer in front of it.

### Database module
- RDS PostgreSQL 15 in private subnets
- `publicly_accessible = false`
- Credentials pulled from AWS Secrets Manager at apply time — no plaintext anywhere
- Multi-AZ subnet group
- Automated backups enabled, `skip_final_snapshot = false`

### Compute module
- ECS Fargate cluster in private subnets
- Task definition pulls DB credentials from Secrets Manager via environment injection
- ALB target group + listener with health checks
- ECS service auto-scaling: scale out when CPU > 70%, scale in when CPU < 30%
- IAM execution role with least-privilege policy (ECS task execution + Secrets Manager read)
- CloudWatch log group: 30-day retention

---

## Module structure

```
aws-terraform-ecs-setup/
│
├── main.tf                    ← calls modules, wires outputs between them
├── variables.tf               ← root inputs
├── outputs.tf                 ← ALB DNS, cluster name
├── terraform.tfvars.example
│
└── modules/
    ├── networking/
    │   ├── main.tf            ← VPC, subnets, IGW, NAT, route tables
    │   ├── variables.tf
    │   └── outputs.tf         ← vpc_id, subnet IDs
    │
    ├── security/
    │   ├── main.tf            ← ALB, ECS, RDS security groups
    │   ├── variables.tf
    │   └── outputs.tf         ← security group IDs
    │
    ├── database/
    │   ├── main.tf            ← RDS, subnet group, Secrets Manager
    │   ├── variables.tf
    │   └── outputs.tf         ← db_endpoint, secret_arn
    │
    └── compute/
        ├── main.tf            ← ECS cluster, task definition, service, ALB, auto-scaling, IAM, CloudWatch
        ├── variables.tf
        └── outputs.tf         ← alb_dns_name
```

---

## Security group chain

```
Internet → ALB SG (0.0.0.0/0:443) → ECS SG (source: ALB SG) → RDS SG (source: ECS SG)
```

The key rule: **security groups reference other security groups as sources, not CIDR blocks.** This means if you add a new ECS container in the same SG, it automatically gets DB access — no manual CIDR management.

---

## Tech stack

| Concern | Choice |
|---|---|
| IaC | Terraform ~> 5.0 AWS provider |
| Compute | AWS ECS Fargate (serverless containers) |
| Database | AWS RDS PostgreSQL 15 |
| Load balancing | AWS ALB (Application Load Balancer) |
| Secrets | AWS Secrets Manager |
| Networking | Custom VPC, public/private subnets, NAT Gateway |
| Observability | CloudWatch Logs (30-day retention) |
| Auto-scaling | ECS Application Auto Scaling on CPU |

---

## Deployment

```bash
# Prerequisites: Terraform >= 1.0, AWS CLI configured

# Copy and fill in your values
cp terraform.tfvars.example terraform.tfvars

# Initialise providers and modules
terraform init

# Review what will be created
terraform plan

# Deploy
terraform apply
```

After apply, the ALB DNS name is printed as an output:

```bash
terraform output alb_dns_name
```

To tear down:

```bash
terraform destroy
```

---

## Infrastructure mental model — quick audit checklist

When jumping into unfamiliar infrastructure, these 6 commands surface 80% of common problems in under a minute:

```bash
grep -r "password\|secret\|key" *.tf    # hardcoded credentials?
grep "0.0.0.0/0" *.tf                   # what is open to the internet?
grep "publicly_accessible" *.tf         # is the DB public?
grep "desired_count" *.tf               # how many tasks are running?
grep "retention_in_days" *.tf           # how long are logs kept?
ls terraform.tfstate                    # is state stored locally?
```
