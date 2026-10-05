# webhook-relay-aws — task runner
# `just` with no argument lists every recipe.

default:
    @just --list

# fmt, validate, then prove the network policy claims
check: fmt validate audit

# Format every .tf file in place
fmt:
    terraform fmt -recursive

# Validate all three roots without contacting AWS
validate:
    terraform init -backend=false -input=false >/dev/null
    terraform validate
    terraform -chdir=bootstrap init -input=false >/dev/null
    terraform -chdir=bootstrap validate
    terraform -chdir=loadtest init -backend=false -input=false >/dev/null
    terraform -chdir=loadtest validate

# Counts rule arguments, not lines, so a comment cannot inflate the number.

# Reproducible evidence for the README's network-policy claims
audit:
    @echo "rules opening something to the whole internet:"
    @grep -rn 'cidr_ipv4 *= *"0.0.0.0/0"' modules/ | sed 's/^/  /'
    @echo
    @echo "rules per security group (target group, direction):"
    @awk 'BEGIN { split("alb api worker rds", G, " "); split("ingress egress", D, " "); \
            for (i in G) for (j in D) count[G[i] "-sg " D[j]] = 0 } \
         /^resource "aws_vpc_security_group_(ingress|egress)_rule"/ { \
            dir = /ingress/ ? "ingress" : "egress"; next } \
         /security_group_id = aws_security_group\./ && dir { \
            match($0, /aws_security_group\.[a-z]+/); \
            g = substr($0, RSTART+19, RLENGTH-19); \
            count[g "-sg " dir]++; dir = "" } \
         END { for (k in count) printf "  %-18s %s\n", k, count[k] }' \
         modules/security/main.tf | sort

# --- local ----------------------------------------------------------------
# Postgres stands in for RDS, ElasticMQ for SQS. No AWS account required.

# Unit tests: the retry curve and the HMAC scheme
test:
    cd app && go test ./...

# ~3 min, most of it waiting out real backoff and visibility timeouts.
# KEEP_STACK=1 reuses the running stack.

# Assert every delivery guarantee from a cold start
verify:
    ./scripts/verify-local.sh

# Bring up postgres, elasticmq, api, worker and the fake subscriber
up-local:
    docker compose up --build -d
    @echo "api  http://localhost:8080"
    @echo "sink http://localhost:9000/stats"

down-local:
    docker compose down -v

logs service="":
    docker compose logs -f {{ service }}

# Happy path: subscribe the sink, POST an event, show the recorded attempt
demo:
    #!/usr/bin/env bash
    set -euo pipefail
    docker compose up -d --force-recreate sink >/dev/null
    sleep 2
    curl -sf -X POST localhost:9000/reset >/dev/null
    curl -sf -X POST localhost:8080/subscriptions \
        -H 'content-type: application/json' \
        -d '{"url":"http://sink:9000/hook","event_type":"invoice.paid"}' | jq .
    id=$(curl -sf -X POST localhost:8080/events \
        -H 'content-type: application/json' \
        -d '{"type":"invoice.paid","payload":{"amount":4200,"currency":"eur"}}' \
        | jq -r .event_id)
    echo "accepted $id"
    sleep 3
    curl -sf "localhost:8080/events/$id" | jq .
    curl -sf localhost:9000/stats | jq .

# --- aws ------------------------------------------------------------------
# Everything here bills. `just down` after every session is the guardrail; the
# Budgets alarm lags by 8-12 hours and is a notification, not protection.

# Once per account. The bucket outlives just down; prevent_destroy refuses to delete it.

# Create the state bucket, the one resource the root configuration cannot create
state:
    terraform -chdir=bootstrap init -input=false
    terraform -chdir=bootstrap apply

# Point the root and loadtest configurations at the bucket that bootstrap/ created
init:
    #!/usr/bin/env bash
    set -euo pipefail
    bucket=$(terraform -chdir=bootstrap output -raw state_bucket)
    region=$(terraform -chdir=bootstrap output -raw region)
    for root in . loadtest; do
      terraform -chdir=$root init -input=false -reconfigure \
        -backend-config="bucket=$bucket" -backend-config="region=$region"
    done

# A full apply first would start services on an image tag that does not exist yet.

# Empty account to running services: budget and ECR first, then images, then everything else
up:
    terraform apply -target=module.observability -target=module.registry
    just push
    just deploy

# The short commit, with -dirty appended when the tree has uncommitted changes.

# Image tag for the current working tree
version:
    @git describe --always --dirty --abbrev=8

# The tag has to change for a deploy to happen: a byte-identical task definition
# produces no diff, so ECS is never told to roll.

# Apply, pinning both services to the image built from this working tree
deploy:
    terraform apply -var image_tag=$(just version)

# Destroy everything, the sink included. The actual cost control — ~$2.05/day if left running.
down:
    terraform -chdir=loadtest destroy
    terraform destroy

# Terraform cannot build images. Built natively for ARM64, matching
# runtime_platform in the task definitions; each image gets an immutable tag and
# `latest`, and `deploy` uses the former.

# Build both service images for ARM64 and push them to ECR
push:
    #!/usr/bin/env bash
    set -euo pipefail
    tag=$(just version)
    urls=$(terraform output -json ecr_repository_urls)
    registry=$(jq -r '.api' <<<"$urls" | cut -d/ -f1)
    region=$(cut -d. -f4 <<<"$registry")
    aws ecr get-login-password --region "$region" \
      | docker login --username AWS --password-stdin "$registry"
    for svc in $(jq -r 'keys[]' <<<"$urls"); do
      url=$(jq -r ".\"$svc\"" <<<"$urls")
      echo "building $svc for linux/arm64 as $tag"
      docker build --platform linux/arm64 --build-arg BINARY="$svc" \
        -t "$url:$tag" -t "$url:latest" app/
      docker push "$url:$tag"
      docker push "$url:latest"
    done
    echo
    echo "pushed $tag — now: just deploy"

# --- load test ------------------------------------------------------------
# The sink and the generator are test fixtures, not part of the system.

# Deploy the counting sink: HTTP API, Lambda, DynamoDB. Zero cost while idle.
sink:
    terraform -chdir=loadtest apply

# Subscribe the sink to an event type under a run label; extra is e.g. fail_until=3
subscribe-sink type run extra="":
    curl -sf -X POST "http://$(terraform output -raw alb_dns_name)/subscriptions" \
      -H 'content-type: application/json' \
      -d "{\"url\":\"$(terraform -chdir=loadtest output -raw sink_url)/hook?run={{ run }}{{ if extra != "" { "&" + extra } else { "" } }}\",\"event_type\":\"{{ type }}\"}" | jq .

# What the sink received for a run label
sink-stats run:
    @curl -sf "$(terraform -chdir=loadtest output -raw sink_url)/stats?run={{ run }}" | jq .

# CloudShell runs on x86_64. Upload the binary through its Actions menu.

# Build the load generator for AWS CloudShell, in the same region as the ALB
loadgen-build:
    cd app && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" \
      -o ../dist/loadgen ./cmd/loadgen
    @echo "dist/loadgen — upload to CloudShell, then: just loadgen-cmd"

# Print the loadgen invocation for this deployment, ready to paste into CloudShell
loadgen-cmd type="load.test" profile="10:30s,1000:5s,10:120s":
    @echo "./loadgen -target http://$(terraform output -raw alb_dns_name) -type {{ type }} \\"
    @echo "  -profile {{ profile }} -queue-url $(terraform output -raw queue_url) \\"
    @echo "  -cluster $(terraform output -raw ecs_cluster_name) -service $(terraform output -raw worker_service_name) > {{ type }}.csv"
