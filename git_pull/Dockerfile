FROM ghcr.io/home-assistant/amd64-base:3.21

RUN apk add --no-cache jq curl git openssh-client curl ca-certificates bash

RUN curl -sL https://taskfile.dev/install.sh | sh -s -- -d -b /usr/local/bin

COPY data/run.sh /

RUN chmod +x /run.sh

CMD [ "/run.sh" ]
