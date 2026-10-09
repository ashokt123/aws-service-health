"""Service health API: GET /health returns status, version, region, and a visit counter.

The kill switch (an SSM parameter) makes the API return 503 so outages can be
demoed without touching infrastructure. Every request logs one JSON line with
its status code; a CloudWatch metric filter counts 5xx lines to drive the alarm.
"""

import json
import os
import time

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
MAINTENANCE_PARAM = os.environ["MAINTENANCE_PARAM"]
APP_VERSION = os.environ.get("APP_VERSION", "dev")
REGION = os.environ.get("AWS_REGION", "unknown")

FLAG_TTL_SECONDS = 5

dynamodb = boto3.client("dynamodb")
ssm = boto3.client("ssm")

_flag_cache = {"value": False, "expires": 0.0}


def maintenance_on():
    """Read the kill switch, cached briefly so we don't call SSM on every request."""
    now = time.time()
    if now >= _flag_cache["expires"]:
        value = ssm.get_parameter(Name=MAINTENANCE_PARAM)["Parameter"]["Value"]
        _flag_cache["value"] = value.strip().lower() == "true"
        _flag_cache["expires"] = now + FLAG_TTL_SECONDS
    return _flag_cache["value"]


def increment_visits():
    result = dynamodb.update_item(
        TableName=TABLE_NAME,
        Key={"pk": {"S": "visits"}},
        UpdateExpression="ADD visits :one",
        ExpressionAttributeValues={":one": {"N": "1"}},
        ReturnValues="UPDATED_NEW",
    )
    return int(result["Attributes"]["visits"]["N"])


def respond(status, body):
    print(json.dumps({"event": "request", "status": status, "detail": body.get("status")}))
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


def handler(event, context):
    path = event.get("rawPath", "/")
    if path not in ("/", "/health"):
        return respond(404, {"status": "not_found"})

    base = {
        "service": "service-health",
        "region": REGION,
        "version": APP_VERSION,
        "timestamp": int(time.time() * 1000),
    }
    try:
        if maintenance_on():
            return respond(503, {**base, "status": "maintenance"})
        return respond(200, {**base, "status": "ok", "visits": increment_visits()})
    except Exception as exc:  # throttling, permissions, etc. -> counted as unhealthy
        print(json.dumps({"event": "error", "type": type(exc).__name__, "message": str(exc)}))
        return respond(500, {**base, "status": "error"})
