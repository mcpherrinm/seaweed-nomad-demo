# Demo app. Run from /jobs so file() can find app.py:
#   nomad job run app.nomad.hcl
# run-demo.sh also submits a copy renamed to "intruder" with -var expect=deny,
# to show the role trusts only this job ID. (Job IDs can't be variables.)

# "allow": STS and S3 access to bucket demo-app should succeed.
# "deny":  the role's trust policy should reject this job's identity.
variable "expect" {
  type    = string
  default = "allow"
}

job "s3-demo-app" {
  type = "batch"

  group "app" {
    restart {
      attempts = 0
      mode     = "fail"
    }
    reschedule {
      attempts  = 0
      unlimited = false
    }

    task "app" {
      # PRODUCTION: exec2, docker or podman. See nomad/client.hcl.
      driver = "raw_exec"

      # An extra workload identity whose audience is SeaweedFS. Nomad signs it,
      # writes it to secrets/nomad_seaweed.jwt and rotates it before expiry.
      # `aud` must match the SeaweedFS provider's clientId. Use one identity per
      # service the task talks to, so a token for one isn't accepted by another.
      identity {
        name = "seaweed"
        aud  = ["seaweedfs"]
        file = true
        ttl  = "1h"
      }

      config {
        command = "python3"
        args    = ["-u", "${NOMAD_TASK_DIR}/app.py"]
      }

      template {
        data            = file("app.py")
        destination     = "local/app.py"
        left_delimiter  = "[[["
        right_delimiter = "]]]"
      }

      # The standard AWS SDK web-identity variables. Any AWS SDK picks these up.
      env {
        EXPECT                      = var.expect
        AWS_ROLE_ARN                = "arn:aws:iam::role/DemoAppRole"
        AWS_ROLE_SESSION_NAME       = "${NOMAD_JOB_ID}-${NOMAD_ALLOC_ID}"
        AWS_WEB_IDENTITY_TOKEN_FILE = "${NOMAD_SECRETS_DIR}/nomad_seaweed.jwt"
        AWS_ENDPOINT_URL            = "https://seaweed:8333"
        # Demo CA, mounted in the client container. PRODUCTION: unnecessary if
        # your CA is in the system trust store, or ship it with the task.
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
