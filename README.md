# webhook-relay-aws

Multi-service event delivery platform on AWS ECS Fargate — Terraform modules, SQS-backed
workers autoscaling on queue depth, private RDS, least-privilege IAM.

---

## The system

`webhook-relay` is the sender side of a webhook system — the component that POSTs to a
customer's URL when something happens in your product, and keeps retrying until it lands.

```
  caller                       relay                      subscriber URL
    │                                                           │
    │ POST /events ──▶ [store + enqueue] ──▶ 202 (instant)       │
    │                       │                                    │
    │                       ├─ attempt 1 ──────────────────▶ 500 ✗
    │                       ├─ attempt 2 (+30s) ───────────▶ timeout ✗
    │                       └─ attempt 3 (+2m) ────────────▶ 200 ✓
    │
    └── never waited for any of it
```

Accepting an event and delivering it are different problems. Accepting must be fast and
always available — the caller is waiting. Delivering is slow, unreliable, and depends
entirely on infrastructure someone else operates. Putting both in one process means a
customer's dead endpoint degrades your ingest path.

So they are two services, and the infrastructure exists to serve that split:

| | `api` | `worker` |
|---|---|---|
| Responsibility | accept, validate, persist, enqueue, `202` | drain queue, deliver, retry, record |
| Traffic shape | steady, latency-critical | bursty, latency-tolerant |
| Scaling signal | ALB request count per target | SQS queue depth |
| Network exposure | public, behind the ALB | private, no inbound rules |
| IAM permissions | `sqs:SendMessage` | `sqs:ReceiveMessage`, `sqs:DeleteMessage` |
| Egress via NAT | not required | required — calls arbitrary customer URLs |
| Failure impact | requests rejected | delivery delayed |

---

## Architecture

```
                              Internet
                                 │
                    ┌────────────▼─────────────┐
                    │  ALB  (public subnets)   │
                    └────────────┬─────────────┘
                                 │
  ── private boundary ───────────┼──────────────────────────────────────
                                 │
        ┌────────────────────────▼──────────┐         ┌──────────────┐
        │  ECS service: webhook-api         │──send──▶│  SQS + DLQ   │
        │  Fargate, 2 AZs, scales on RPS    │         └──────┬───────┘
        └────────────────┬──────────────────┘                │ receive
                         │                    ┌───────────────▼─────────┐
                         │                    │ ECS service: webhook-   │
                         │                    │ worker — no ALB, scales │
                         │                    │ on queue depth          │
                         │                    └───────┬─────────┬───────┘
                         │ :5432                      │ :5432   │ :443 out
              ┌──────────▼────────────────────────────▼───┐     │
              │        RDS PostgreSQL (private)           │     │
              └───────────────────────────────────────────┘     ▼
                                                      NAT GW ──▶ subscribers
```

The ALB is the only resource with a public address. Both ECS services run in private
subnets; the worker reaches the internet outbound through the NAT gateway and accepts no
inbound connections at all.

### Network layout

| Tier | Subnets | Reachable from |
|---|---|---|
| Load balancer | 2 public, one per AZ | the internet |
| ECS tasks | 2 private, one per AZ | the ALB (api only) |
| RDS | same private subnets, dedicated subnet group | the ECS security groups |

Two availability zones throughout: the ALB requires subnets in at least two, and the RDS
subnet group and ECS services follow the same boundary so a single AZ failure degrades
rather than stops the system.

### Security groups

```
0.0.0.0/0 ──▶ alb-sg ──▶ api-sg ──┐
                                  ├──▶ rds-sg  (:5432, SG source, never a CIDR)
              (no ingress) worker-sg ──┘
                                  └──▶ 0.0.0.0/0 :443 egress only, via NAT
```

Rules reference **other security groups** as their source rather than CIDR blocks. A new
task placed in `api-sg` gains database access by membership, so no IP addresses are managed
by hand as tasks are replaced. `worker-sg` declares no ingress rules — nothing on the
network can open a connection to a worker.

### Delivery semantics

SQS owns the retry schedule and the failure boundary. The worker deletes a message only
after a `2xx` from the subscriber; anything else leaves the message to reappear after its
visibility timeout, and the redrive policy moves it to the dead-letter queue after a fixed
number of attempts. Retries are therefore a queue configuration rather than application
code, and a message that can never be delivered ends up somewhere inspectable instead of
looping forever.

Delivery is at-least-once. Subscribers are expected to be idempotent, which is the same
contract Stripe and GitHub publish for their own webhooks.

---

## Application

Four endpoints, three tables. The application is intentionally small — its purpose is to
exercise the infrastructure honestly, not to be a product.

```
POST /events            {"type":"invoice.paid","payload":{...}}      → 202 {event_id}
POST /subscriptions     {"url":"https://...","event_type":"..."}     → 201
GET  /events/{id}       event and its delivery attempts
GET  /healthz           ALB health check target
```

```sql
subscriptions      (id, url, event_type, secret, active, created_at)
events             (id, type, payload jsonb, created_at)
delivery_attempts  (id, event_id, subscription_id, attempt_no,
                    status_code, error, duration_ms, attempted_at)
```

Each delivery is signed with an HMAC of the request body using the subscription's secret,
so a subscriber can verify the request genuinely came from the relay.

---

## Repository layout

```
main.tf                  module composition and provider configuration
variables.tf             root inputs
outputs.tf               ALB DNS name, VPC and subnet IDs
modules/
  networking/            VPC, public and private subnets, IGW, NAT gateway, route tables
  security/              security groups: alb, api, worker, rds
  messaging/             SQS queue, dead-letter queue, redrive policy
  registry/              ECR repositories and image lifecycle policy
  database/              RDS PostgreSQL, subnet group, Secrets Manager integration
  alb/                   load balancer, target group, listener, health checks
  ecs/                   cluster, task definitions, services, IAM roles, autoscaling, logs
app/
  cmd/api/               ingest service
  cmd/worker/            delivery service
  migrations/            schema
```

Security groups live in their own module rather than beside the resources they protect, so
the trust relationships between tiers are visible in one file and wired explicitly in
`main.tf` instead of being implied across several modules.

---

## Design decisions

**SQS rather than a database-polling queue.** Delivery needs retries with backoff, a
visibility timeout, and a dead-letter destination. All three are queue configuration in SQS
and hand-written code against Postgres, and the worker's scaling signal — queue depth — is
a CloudWatch metric that exists without instrumentation.

**Fargate rather than EC2.** The workload is two stateless services with bursty demand. EC2
would add capacity management and AMI maintenance in exchange for cost savings that only
matter at sustained scale.

**NAT gateway rather than VPC endpoints.** The worker calls arbitrary customer URLs on the
public internet, so it needs general egress regardless. VPC endpoints for SQS and Secrets
Manager would reduce NAT data charges but cannot replace it.

**Credentials in Secrets Manager.** The RDS password is generated and stored at apply time
and injected into the task definition by reference, so it appears neither in the repository
nor in `terraform.tfvars`.

### Deliberately out of scope

No TLS certificate or custom domain — the ALB serves HTTP on its AWS-assigned DNS name. No
multi-region deployment. No exactly-once delivery, which is not achievable across a network
boundary; the system provides at-least-once delivery and a documented idempotency contract.

---

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in region, project name, CIDRs
terraform init                                  # download the AWS provider, link modules
terraform plan                                  # review the diff before touching AWS
terraform apply
terraform output alb_dns_name
```

```bash
terraform destroy
```

The NAT gateway, ALB, and RDS instance bill hourly whether or not traffic flows —
approximately $2–3 per day for this stack.
