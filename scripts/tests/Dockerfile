# A machine that has never been provisioned, for `make test-container`: Ubuntu
# 22.04, the oldest release the installer supports, with a user who can sudo
# and nothing the installer is meant to bring. python3 is left out on purpose,
# so scripts/install.sh has to install it. The package lists are deleted for
# the same reason: a fresh machine may never have fetched them.
FROM ubuntu:22.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        sudo ca-certificates openssh-client \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --shell /bin/bash tester \
    && echo 'tester ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/tester

USER tester
WORKDIR /home/tester
