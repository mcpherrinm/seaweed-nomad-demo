# Publishes a small static site into the "public" bucket that nginx serves.
# Same workload identity flow as app.nomad.hcl, but a different role:
# PublisherRole may manage only the "public" bucket, including its bucket policy.
# Run from /jobs so file() can find publisher.py:
#   nomad job run publisher.nomad.hcl

job "s3-publisher" {
  type = "batch"

  group "publish" {
    restart {
      attempts = 0
      mode     = "fail"
    }
    reschedule {
      attempts  = 0
      unlimited = false
    }

    task "publish" {
      # PRODUCTION: exec2, docker or podman. See nomad/client.hcl.
      driver = "raw_exec"

      identity {
        name = "seaweed"
        aud  = ["seaweedfs"]
        file = true
        ttl  = "1h"
      }

      config {
        command = "python3"
        args    = ["-u", "${NOMAD_TASK_DIR}/publisher.py"]
      }

      template {
        data            = file("publisher.py")
        destination     = "local/publisher.py"
        left_delimiter  = "[[["
        right_delimiter = "]]]"
      }

      env {
        AWS_ROLE_ARN                = "arn:aws:iam::role/PublisherRole"
        AWS_ROLE_SESSION_NAME       = "${NOMAD_JOB_ID}-${NOMAD_ALLOC_ID}"
        AWS_WEB_IDENTITY_TOKEN_FILE = "${NOMAD_SECRETS_DIR}/nomad_seaweed.jwt"
        AWS_ENDPOINT_URL            = "https://seaweed:8333"
        AWS_CA_BUNDLE               = "/pki/ca.crt"
        AWS_REGION                  = "us-east-1"
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
