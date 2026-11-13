FROM golang:1.26.3-alpine
RUN go install github.com/jsha/minica@v1.1.0
COPY gen-pki.sh /usr/local/bin/gen-pki.sh
ENTRYPOINT ["/bin/sh", "/usr/local/bin/gen-pki.sh"]
