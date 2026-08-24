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

# Counts rule arguments, never lines of text, so a comment cannot inflate a
# number.

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

# ---------------------------------------------------------------------------
# The app, locally. No AWS account, no credentials, no cost.
# Postgres stands in for RDS, ElasticMQ for SQS. Same code, same env vars.
# ---------------------------------------------------------------------------

# Unit tests: the retry curve and the HMAC scheme
test:
    cd app && go test ./...

# Exits non-zero when a guarantee breaks. ~3 min, most of it waiting out real
# backoff and visibility timeouts. KEEP_STACK=1 reuses the running stack.

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

# ---------------------------------------------------------------------------
# AWS. Everything here bills. `just down` after every session is the guardrail;
# the Budgets alarm is a lagging notification with an 8-12 hour delay, not
# protection.
# ---------------------------------------------------------------------------

# The short commit, with -dirty appended when the tree has uncommitted changes.
# Immutable per build, and that is the point — see `deploy`.

# Image tag for the current working tree
version:
    @git describe --always --dirty --abbrev=8

# The tag has to change for a deploy to happen at all. A task definition that is
# byte-identical produces no Terraform diff, so ECS is never told to do anything
# and the service keeps running the old image. Tagging everything `latest` and
# re-applying looks like a deploy and is a no-op.

# Apply, pinning both services to the image built from this working tree
deploy:
    terraform apply -var image_tag=$(just version)

# Destroy everything. The actual cost control — ~$2.05/day if left running.
down:
    terraform destroy

# Terraform cannot build images, so this is a recipe rather than a resource.
#
# Built natively for ARM64. Fargate defaults to x86_64, and an arm64 image
# deployed onto that fails at task start with "exec format error" — the most
# common first-deploy failure in this shape of project. The task definitions set
# runtime_platform ARM64 to match, and ARM64 Fargate is also about 20% cheaper.
# Each image gets both an immutable tag and `latest`; `deploy` uses the former.

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
