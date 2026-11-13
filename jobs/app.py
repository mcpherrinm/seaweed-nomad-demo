"""Demo app: authenticate to SeaweedFS S3 with this task's Nomad workload identity.

Uses only the standard AWS web-identity environment variables, which Nomad's
job spec sets: AWS_ROLE_ARN, AWS_WEB_IDENTITY_TOKEN_FILE, AWS_ENDPOINT_URL.
"""

import base64
import json
import os
import sys

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

ENDPOINT = os.environ["AWS_ENDPOINT_URL"]
BUCKET = "demo-app"
EXPECT = os.environ.get("EXPECT", "allow")
S3_CONFIG = Config(s3={"addressing_style": "path"})


def step(msg):
    print(f"\n==> {msg}")


def decode_jwt_payload(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def header(token):
    h = token.split(".")[0]
    h += "=" * (-len(h) % 4)
    return json.loads(base64.urlsafe_b64decode(h))


def main():
    token_file = os.environ["AWS_WEB_IDENTITY_TOKEN_FILE"]
    with open(token_file) as f:
        token = f.read().strip()

    step(f"Nomad workload identity JWT from {token_file}")
    print("header:", json.dumps(header(token)))
    print("claims:", json.dumps(decode_jwt_payload(token), indent=2))

    step(f"sts:AssumeRoleWithWebIdentity -> {os.environ['AWS_ROLE_ARN']}")
    sts = boto3.client("sts", endpoint_url=ENDPOINT)
    try:
        resp = sts.assume_role_with_web_identity(
            RoleArn=os.environ["AWS_ROLE_ARN"],
            RoleSessionName=os.environ["AWS_ROLE_SESSION_NAME"],
            WebIdentityToken=token,
        )
    except ClientError as e:
        print("STS refused:", e.response["Error"].get("Code"), "-", e.response["Error"].get("Message"))
        if EXPECT == "deny":
            print("\nRESULT: PASS (this job is not trusted by the role, as expected)")
            return 0
        print("\nRESULT: FAIL")
        return 1

    if EXPECT == "deny":
        print("STS issued credentials to a job the role should not trust!")
        print("\nRESULT: FAIL")
        return 1

    creds = resp["Credentials"]
    print("AssumedRoleUser:", resp.get("AssumedRoleUser", {}).get("Arn"))
    print("AccessKeyId:", creds["AccessKeyId"])
    print("Expiration:", creds["Expiration"])

    s3 = boto3.client(
        "s3",
        endpoint_url=ENDPOINT,
        aws_access_key_id=creds["AccessKeyId"],
        aws_secret_access_key=creds["SecretAccessKey"],
        aws_session_token=creds["SessionToken"],
        config=S3_CONFIG,
    )

    step(f"Create bucket {BUCKET} (if needed), put and get an object")
    try:
        s3.head_bucket(Bucket=BUCKET)
    except ClientError:
        s3.create_bucket(Bucket=BUCKET)
    key = f"hello-from-{os.environ['NOMAD_ALLOC_ID']}.txt"
    s3.put_object(Bucket=BUCKET, Key=key, Body=b"written with a Nomad workload identity\n")
    body = s3.get_object(Bucket=BUCKET, Key=key)["Body"].read()
    print(f"s3://{BUCKET}/{key}: {body!r}")
    listing = s3.list_objects_v2(Bucket=BUCKET).get("Contents", [])
    print(f"{BUCKET} now holds {len(listing)} object(s)")

    step("Least privilege: the role's policy should block another bucket")
    try:
        s3.create_bucket(Bucket="someone-elses-bucket")
        print("Unexpectedly allowed!")
        print("\nRESULT: FAIL")
        return 1
    except ClientError as e:
        print("Denied as expected:", e.response["Error"].get("Code"))

    step("Same thing via the default AWS credential chain (no explicit STS call)")
    # boto3 reads AWS_ROLE_ARN + AWS_WEB_IDENTITY_TOKEN_FILE itself, calls STS at
    # AWS_ENDPOINT_URL, and refreshes credentials before they expire.
    try:
        auto = boto3.client("s3", config=S3_CONFIG)
        n = len(auto.list_objects_v2(Bucket=BUCKET).get("Contents", []))
        print(f"listed {n} object(s) in {BUCKET} using SDK-managed credentials")
    except Exception as e:  # noqa: BLE001 - report, don't hide, SDK-path problems
        print(f"default credential chain failed: {type(e).__name__}: {e}")
        print("\nRESULT: FAIL")
        return 1

    print("\nRESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
