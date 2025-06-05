FROM ubuntu:latest

RUN apt update

RUN apt install curl ripgrep xz-utils nodejs btop lsof npm -y && \
  curl -LO https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz

RUN tar -xf zig-linux-x86_64-0.14.0.tar.xz && \
    ln -sfn /zig-linux-x86_64-0.14.0/zig /usr/bin/zig

RUN apt install -y tini

ENTRYPOINT ["/usr/bin/tini", "--"]

CMD ["tail", "-f", "/dev/null"]
