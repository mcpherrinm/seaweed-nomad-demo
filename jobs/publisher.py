"""Publish a tiny static site to the "public" bucket and make it anonymously readable.

Credentials come from the default AWS chain: the SDK trades this task's Nomad
workload identity JWT for PublisherRole credentials (see publisher.nomad.hcl).
"""

import json
import sys

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

BUCKET = "public"

# Anonymous callers may read objects, and nothing else: no listing, no writes,
# no reading the policy or ACLs.
PUBLIC_READ_POLICY = {
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "PublicReadObjects",
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:GetObject"],
            "Resource": [f"arn:aws:s3:::{BUCKET}/*"],
        }
    ],
}

FILES = {
    "index.html": (
        "text/html; charset=utf-8",
        "<!doctype html><title>Public bucket</title>"
        "<h1>Served from SeaweedFS through nginx</h1>"
        '<p>Uploaded by a Nomad job using its workload identity. See <a href="hello.txt">hello.txt</a>.</p>\n',
    ),
    "hello.txt": ("text/plain; charset=utf-8", "hello from the public bucket\n"),
}


def main():
    s3 = boto3.client("s3", config=Config(s3={"addressing_style": "path"}))

    print(f"==> Ensuring bucket {BUCKET} exists")
    try:
        s3.head_bucket(Bucket=BUCKET)
    except ClientError:
        s3.create_bucket(Bucket=BUCKET)

    print("==> Setting anonymous read-only bucket policy")
    s3.put_bucket_policy(Bucket=BUCKET, Policy=json.dumps(PUBLIC_READ_POLICY))
    print(s3.get_bucket_policy(Bucket=BUCKET)["Policy"])

    for key, (content_type, body) in FILES.items():
        print(f"==> Uploading {key}")
        s3.put_object(Bucket=BUCKET, Key=key, Body=body.encode(), ContentType=content_type)

    print("==> PublisherRole must not reach other buckets")
    try:
        s3.list_objects_v2(Bucket="demo-app")
        print("Unexpectedly allowed!\n\nRESULT: FAIL")
        return 1
    except ClientError as e:
        print("Denied as expected:", e.response["Error"].get("Code"))

    print("\nRESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
