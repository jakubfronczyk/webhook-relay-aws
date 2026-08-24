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
| Scaling signal | ALB request count per target | SQS backlog per task |
| Network exposure | public, behind the ALB | private, no inbound rules |
| IAM permissions | `sqs:SendMessage` | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility` |
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

The split is worth stating precisely, because half of it is queue configuration and half
of it is application code.

**SQS owns** durability, redelivery, the attempt ceiling (`maxReceiveCount`) and the
dead-letter queue. A message that can never be delivered ends up somewhere inspectable
instead of looping forever, and that is configuration, not code.

**The worker owns** the backoff curve and the signature. SQS has no exponential-backoff
setting — only a single fixed visibility timeout — so the growing interval comes from the
worker calling `ChangeMessageVisibility` per message with a delay derived from
`ApproximateReceiveCount`. It deletes a message only after every subscriber for that event
has returned `2xx`.

Delivery is at-least-once. Subscribers are expected to be idempotent, which is the same
contract Stripe and GitHub publish for their own webhooks. Two consequences the code
handles explicitly: a subscriber that already returned `2xx` is skipped when a message is
redelivered because a *different* subscriber failed, and a request that times out is
retried even though the subscriber may well have processed it — from the sender's side those
two outcomes are indistinguishable.

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

## Run it locally

No AWS account, no credentials, no cost. Postgres stands in for RDS and
[ElasticMQ](https://github.com/softwaremill/elasticmq) for SQS — ElasticMQ speaks the SQS
wire protocol, so the application has one queue implementation and only the endpoint URL
changes between a laptop and Fargate.

```bash
just up-local     # postgres, elasticmq, api, worker, and a fake subscriber
just demo         # register the subscriber, POST an event, show the recorded attempt
just verify       # assert every guarantee below, from a cold start
just down-local
```

`just verify` is the one that matters. It wipes the stack, rebuilds it, and asserts each
claim on this page rather than printing output for a human to eyeball. Delivery semantics
are the easiest thing in a system like this to believe without evidence, so they are the
part that most needs a test that can fail. It takes about three minutes, most of it spent
waiting out real backoff and visibility timeouts.

```
── api contract
  ✓ creating a subscription returns its signing secret
  ✓ re-registering does NOT return the secret

── retry curve
  ✓ attempts are 1, 2, 3 and fail, fail, succeed
  ✓ first retry waits ~2s (got 2s)
  ✓ second retry waits ~4s (got 4s)

── poison message reaches the dlq
  ✓ exactly maxReceiveCount attempts, then it stops
  ✓ the message moved to the dead-letter queue

── durability: the fleet dies mid-drain
  ✓ the api accepted all 200
  ✓ every accepted event reached the subscriber
  ✓ the subscriber's own tally agrees
  ✓ duplicates stayed within WORKER_CONCURRENCY (8)

PASS  25 checks
```

Attempt numbers come from SQS's `ApproximateReceiveCount` rather than from anything the
worker remembers, and the attempt ceiling is the queue's `maxReceiveCount` rather than
worker code. The last block is the interesting one: the worker fleet is `SIGKILL`ed at peak
backlog, and afterwards three independently kept counts — the events table, the
`delivery_attempts` table, and a tally kept by the subscriber itself — agree that nothing
was lost.

Eight deliveries arrived twice, and the eight is not noise: it equals `WORKER_CONCURRENCY`,
because those are exactly the deliveries in flight when the process died — already accepted
by the subscriber, never acknowledged to SQS, so redelivered once the visibility timeout
expired. That is what at-least-once means, and it is why every delivery carries a stable
event id.

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
  cmd/sink/              fake subscriber, counts what it receives — test fixture, not part
                         of the system
  internal/queue/        one SQS client for both ElasticMQ and AWS
  internal/relay/        the delivery loop, the backoff curve
  internal/sign/         HMAC signing, and the verification half the sink uses
  internal/store/        every query against Postgres
  migrations/            schema, embedded into the binaries
  Dockerfile             one build, parameterised by --build-arg BINARY
docker-compose.yml       the whole system locally: no AWS account, no credentials
elasticmq.conf           local stand-in for SQS, same wire protocol
justfile                 terraform checks, the network-policy audit, the local demos
scripts/verify-local.sh  asserts every delivery guarantee from a cold start
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

**The database password is RDS-managed.** `manage_master_user_password = true` makes RDS
create and own the Secrets Manager secret, so the value never enters Terraform state. The
common alternative — `random_password` plus a secret version — writes the password into
`terraform.tfstate` in plaintext.

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
terraform output queue_url
```

```bash
terraform destroy
```

The NAT gateway, ALB, and RDS instance bill hourly whether or not traffic flows —
approximately $2–3 per day for this stack.
