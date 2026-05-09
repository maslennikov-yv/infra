#!/usr/bin/env python3
"""Build MinIO IAM policy JSON for app accounts.

Subcommands:
  app          — combined RBAC policy for app user (multi-bucket).
                 Reads BUCKETS env (JSON array of {bucket, prefix?, access_mode?}).
  app-single   — same, but for one bucket. Reads BUCKET, PREFIX (optional),
                 ACCESS_MODE env vars (no JSON array assembly required).
  public       — anonymous (public-read) policy for one bucket.
                 Reads BUCKET, PREFIX (optional), PUBLIC_LIST=true|false env vars.

Output: compact JSON to stdout (`mc admin policy create` accepts it).
"""
import json
import os
import sys

ACTS = {
    "private_rw": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
    "private_ro": ["s3:GetObject"],
    "private_wo": [
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListMultipartUploadParts",
    ],
}


def app_policy(buckets):
    stmts = []
    for e in buckets:
        b = e["bucket"]
        p = e.get("prefix") or ""
        list_stmt = {
            "Effect": "Allow",
            "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
            "Resource": ["arn:aws:s3:::" + b],
        }
        if p:
            list_stmt["Condition"] = {"StringLike": {"s3:prefix": [p + "*"]}}
        mode = e.get("access_mode") or "private_rw"
        acts = ACTS.get(mode, ACTS["private_rw"])
        obj_res = (
            "arn:aws:s3:::" + b + "/" + p + "*"
            if p
            else "arn:aws:s3:::" + b + "/*"
        )
        obj_stmt = {"Effect": "Allow", "Action": acts, "Resource": [obj_res]}
        stmts.extend([list_stmt, obj_stmt])
    return {"Version": "2012-10-17", "Statement": stmts}


def public_policy(bucket, prefix, include_list):
    pub_res = (
        "arn:aws:s3:::" + bucket + "/" + prefix + "*"
        if prefix
        else "arn:aws:s3:::" + bucket + "/*"
    )
    stmts = [
        {
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:GetObject"],
            "Resource": [pub_res],
        }
    ]
    if include_list:
        list_stmt = {
            "Effect": "Allow",
            "Principal": "*",
            "Action": ["s3:GetBucketLocation", "s3:ListBucket"],
            "Resource": ["arn:aws:s3:::" + bucket],
        }
        if prefix:
            list_stmt["Condition"] = {"StringLike": {"s3:prefix": [prefix + "*"]}}
        stmts.append(list_stmt)
    return {"Version": "2012-10-17", "Statement": stmts}


def main():
    if len(sys.argv) < 2:
        sys.exit("usage: minio-build-app-policy.py {app|app-single|public}")
    cmd = sys.argv[1]
    if cmd == "app":
        buckets = json.loads(os.environ["BUCKETS"])
        out = app_policy(buckets)
    elif cmd == "app-single":
        out = app_policy([{
            "bucket": os.environ["BUCKET"],
            "prefix": os.environ.get("PREFIX") or "",
            "access_mode": os.environ.get("ACCESS_MODE") or "private_rw",
        }])
    elif cmd == "public":
        bucket = os.environ["BUCKET"]
        prefix = os.environ.get("PREFIX") or ""
        include_list = (os.environ.get("PUBLIC_LIST") or "false").lower() == "true"
        out = public_policy(bucket, prefix, include_list)
    else:
        sys.exit("usage: minio-build-app-policy.py {app|app-single|public}")
    print(json.dumps(out, separators=(",", ":")))


if __name__ == "__main__":
    main()
