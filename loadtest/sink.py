"""Fake subscriber for the AWS load run. Not part of the system.

POST /hook?run=<label>[&fail_rate=0.3][&fail_until=2]   tally one delivery under <label>
GET  /stats?run=<label>                                  the tally, shaped like the compose sink's

The run label lives in the subscription URL, so every proof gets its own tally with no reset.
"""

import json
import os
import random

import boto3
from boto3.dynamodb.conditions import Key

table = boto3.resource("dynamodb").Table(os.environ["TABLE"])


def handler(event, _context):
    method = event["requestContext"]["http"]["method"]
    path = event["rawPath"]
    query = event.get("queryStringParameters") or {}
    run = query.get("run", "default")

    if method == "POST" and path == "/hook":
        return hook(event.get("headers") or {}, query, run)
    if method == "GET" and path == "/stats":
        return stats(run)
    return respond(404, {"error": "not found"})


def hook(headers, query, run):
    # HTTP API lowercases header names.
    event_id = headers.get("x-webhook-event-id", "")
    attempt = int(headers.get("x-webhook-attempt", "0") or 0)
    if not event_id:
        return respond(400, {"error": "missing X-Webhook-Event-Id"})

    fail_until = int(query.get("fail_until", "0"))
    fail_rate = float(query.get("fail_rate", "0"))
    # 500, not 4xx, which would signal a permanent rejection.
    if attempt <= fail_until or random.random() < fail_rate:
        table.update_item(
            Key={"run": run, "event_id": "#rejected"},
            UpdateExpression="ADD received :one",
            ExpressionAttributeValues={":one": 1},
        )
        return respond(500, {"error": "simulated subscriber failure"})

    table.update_item(
        Key={"run": run, "event_id": event_id},
        UpdateExpression="ADD received :one",
        ExpressionAttributeValues={":one": 1},
    )
    return respond(200, {"ok": True})


def stats(run):
    unique = accepted = rejected = 0
    kwargs = {"KeyConditionExpression": Key("run").eq(run)}
    while True:
        page = table.query(**kwargs)
        for item in page["Items"]:
            n = int(item["received"])
            if item["event_id"] == "#rejected":
                rejected = n
            else:
                unique += 1
                accepted += n
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    return respond(200, {
        "run": run,
        "requests": accepted + rejected,
        "accepted": accepted,
        "rejected": rejected,
        "unique_events": unique,
        "duplicate_recv": accepted - unique,
    })


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }
