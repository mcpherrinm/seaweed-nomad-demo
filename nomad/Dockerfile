FROM ubuntu:26.04

ARG NOMAD_VERSION=2.1.1

# python3-boto3 is for the demo app, which runs under raw_exec on the client.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl unzip iproute2 python3 python3-boto3 \
 && rm -rf /var/lib/apt/lists/*

RUN arch="$(dpkg --print-architecture)" \
 && curl -fsSLo /tmp/nomad.zip \
      "https://releases.hashicorp.com/nomad/${NOMAD_VERSION}/nomad_${NOMAD_VERSION}_linux_${arch}.zip" \
 && unzip /tmp/nomad.zip -d /usr/local/bin nomad \
 && rm /tmp/nomad.zip \
 && nomad version

ENV NOMAD_ADDR=http://127.0.0.1:4646
ENTRYPOINT ["nomad"]
