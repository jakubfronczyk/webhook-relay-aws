# webhook-relay-aws — task runner
# `just` with no argument lists every recipe.

default:
    @just --list

# fmt, validate, then prove the network policy claims
check: fmt validate audit

# Format every .tf file in place
fmt:
    terraform fmt -recursive

# Validate the configuration without contacting AWS
validate:
    terraform validate

# Reproducible evidence for the claims the README makes about network policy.
# Counts rule arguments, never lines of text, so a comment cannot inflate a number.
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

# ---------------------------------------------------------------------------
# The app, locally. No AWS account, no credentials, no cost.
# Postgres stands in for RDS, ElasticMQ for SQS. Same code, same env vars.
# ---------------------------------------------------------------------------

# Unit tests: the retry curve and the HMAC scheme
test:
    cd app && go test ./...

# Every delivery guarantee, asserted from a cold start. Exits non-zero when one
# breaks. ~3 min, most of it waiting out real backoff and visibility timeouts.
# KEEP_STACK=1 reuses the running stack instead of rebuilding.
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

# ---------------------------------------------------------------------------
# AWS. Everything here bills. `just down` after every session is the guardrail;
# the Budgets alarm is a lagging notification with an 8-12 hour delay, not
# protection.
# ---------------------------------------------------------------------------

deploy:
    terraform apply

# The actual cost control. ~$2.05/day if left running.
down:
    terraform destroy

# Build both service images and push them to ECR. Terraform cannot build images,
# so this is a recipe rather than a resource.
#
# Built natively for ARM64. Fargate defaults to x86_64, and a darwin/arm64 build
# deployed onto that fails at runtime with "exec format error" — the single most
# common first deploy failure. ARM64 Fargate is also about 20% cheaper, so the
# task definitions in Phase 4 set runtime_platform ARM64 and the build stays
# native. The alternative is --platform linux/amd64 here and emulated builds.
push tag="latest":
    #!/usr/bin/env bash
    set -euo pipefail
    urls=$(terraform output -json ecr_repository_urls)
    registry=$(jq -r '.api' <<<"$urls" | cut -d/ -f1)
    region=$(cut -d. -f4 <<<"$registry")
    aws ecr get-login-password --region "$region" \
      | docker login --username AWS --password-stdin "$registry"
    for svc in api worker; do
      url=$(jq -r ".$svc" <<<"$urls")
      echo "building $svc for linux/arm64"
      docker build --platform linux/arm64 --build-arg BINARY="$svc" -t "$url:{{ tag }}" app/
      docker push "$url:{{ tag }}"
    done
