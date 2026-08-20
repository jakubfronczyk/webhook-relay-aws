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
