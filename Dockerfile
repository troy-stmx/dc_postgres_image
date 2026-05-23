# ============================================================
# Stage 1: Build PostgreSQL + pgvector + VectorChord
# ============================================================
FROM debian:bookworm AS build

ARG POSTGRES_VERSION=16.11
ARG PGVECTOR_VERSION=0.8.0
ARG VCHORD_VERSION=1.1.1
ARG SCWS_VERSION=1.2.3
ARG ZHPARSER_VERSION=2.3

ENV DEBIAN_FRONTEND=noninteractive

RUN apt update \
  && apt install --no-install-recommends -y ca-certificates \
  && echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" >/etc/apt/sources.list \
  && echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >>/etc/apt/sources.list \
  && echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >>/etc/apt/sources.list \
  && echo "deb https://mirrors.ustc.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware" >>/etc/apt/sources.list \
  && rm -rf /etc/apt/sources.list.d/* \
  && apt update \
  && apt install --no-install-recommends -y \
    build-essential ninja-build git curl wget \
    bison flex libxslt1-dev libzstd-dev libicu-dev libkrb5-dev libedit-dev \
    pkg-config gettext locales clang-16 libclang-16-dev zlib1g-dev \
    autoconf automake libtool \
  && apt clean \
  && rm -rf /var/lib/apt/lists/*

# Build PostgreSQL
RUN tmpdir=$(mktemp -d) \
  && cd "$tmpdir" \
  && curl -fsSL https://ftp.postgresql.org/pub/source/v${POSTGRES_VERSION}/postgresql-${POSTGRES_VERSION}.tar.gz -o postgresql.tar.gz \
  && tar -xf postgresql.tar.gz \
  && cd postgresql-${POSTGRES_VERSION} \
  && ./configure --prefix=/usr/local/pgsql \
  && make -j"$(nproc)" \
  && make install \
  && cd contrib \
  && make -j"$(nproc)" \
  && make install \
  && cd /tmp \
  && rm -rf "$tmpdir"

# Build pgvector
RUN tmpdir=$(mktemp -d) \
  && cd "$tmpdir" \
  && curl -fsSL https://github.com/pgvector/pgvector/archive/refs/tags/v${PGVECTOR_VERSION}.tar.gz -o pgvector.tar.gz \
  && tar -xf pgvector.tar.gz \
  && cd pgvector-${PGVECTOR_VERSION} \
  && make -j"$(nproc)" PG_CONFIG=/usr/local/pgsql/bin/pg_config \
  && make install PG_CONFIG=/usr/local/pgsql/bin/pg_config \
  && cd /tmp \
  && rm -rf "$tmpdir"

# Build VectorChord
RUN tmpdir=$(mktemp -d) \
  && curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal \
  && . "$HOME/.cargo/env" \
  && cd "$tmpdir" \
  && git clone --depth 1 --branch ${VCHORD_VERSION} https://github.com/tensorchord/VectorChord.git \
  && cd VectorChord \
  && CC=clang-16 PG_CONFIG=/usr/local/pgsql/bin/pg_config make build \
  && PG_CONFIG=/usr/local/pgsql/bin/pg_config make install \
  && cd /tmp \
  && rm -rf "$tmpdir" \
  && rm -rf "$HOME/.cargo" "$HOME/.rustup"

# Build scws (Simple Chinese Word Segmentation)
RUN tmpdir=$(mktemp -d) \
  && cd "$tmpdir" \
  && git clone --branch ${SCWS_VERSION} --single-branch --depth 1 https://github.com/hightman/scws.git \
  && cd scws \
  && touch README \
  && aclocal \
  && autoconf \
  && autoheader \
  && libtoolize \
  && automake --add-missing \
  && ./configure --prefix=/usr/local \
  && make -j"$(nproc)" \
  && make install \
  && cd /tmp \
  && rm -rf "$tmpdir"

# Build zhparser (Chinese text search parser for PostgreSQL)
RUN tmpdir=$(mktemp -d) \
  && cd "$tmpdir" \
  && git clone --branch v${ZHPARSER_VERSION} --single-branch --depth 1 https://github.com/amutu/zhparser.git \
  && cd zhparser \
  && make -j"$(nproc)" PG_CONFIG=/usr/local/pgsql/bin/pg_config SCWS_HOME=/usr/local \
  && make install PG_CONFIG=/usr/local/pgsql/bin/pg_config SCWS_HOME=/usr/local \
  && cd /tmp \
  && rm -rf "$tmpdir"

# ============================================================
# Stage 2: Runtime image without the build toolchain
# ============================================================
FROM ghcr.io/astral-sh/uv:latest AS uv-bin

FROM debian:bookworm AS runtime

LABEL maintainer="Troy Liu <troyliu0105@outlook.com>"
LABEL org.opencontainers.image.title="dc-postgres-image"
LABEL org.opencontainers.image.description="PostgreSQL runtime image with pgvector, VectorChord and zhparser for Data Closing"
LABEL org.opencontainers.image.source="https://github.com/troyliu0105/dc_postgres_image"

ARG PYTHON_VERSION=3.11
ARG TINI_VERSION=v0.19.0

ENV LANG="zh_CN.UTF-8"
ENV LC_ALL="zh_CN.UTF-8"
ENV DEBIAN_FRONTEND=noninteractive

# Install runtime dependencies and PostgreSQL runtime libraries
RUN apt update \
  && apt install --no-install-recommends -y ca-certificates \
  && echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free non-free-firmware" >/etc/apt/sources.list \
  && echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free non-free-firmware" >>/etc/apt/sources.list \
  && echo "deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free non-free-firmware" >>/etc/apt/sources.list \
  && echo "deb https://mirrors.ustc.edu.cn/debian-security/ bookworm-security main contrib non-free non-free-firmware" >>/etc/apt/sources.list \
  && rm -rf /etc/apt/sources.list.d/* \
  && apt update \
  && apt install --no-install-recommends -y \
    curl wget fish tmux vim htop rsync git git-lfs \
    libxslt1.1 libzstd1 libicu72 libkrb5-3 libedit2 zlib1g \
    locales openssh-server fontconfig fonts-wqy-zenhei \
  && sed -i '/zh_CN.UTF-8/s/^# //g' /etc/locale.gen \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen \
  && update-locale LC_ALL=zh_CN.UTF-8 LANG=zh_CN.UTF-8 \
  && mkdir -p /run/sshd \
  && sed -ri 's/^[#[:space:]]*PasswordAuthentication\s+.*/PasswordAuthentication yes/' /etc/ssh/sshd_config \
  && sed -ri 's/^[#[:space:]]*Port\s+.*/Port 22/' /etc/ssh/sshd_config \
  && sed -ri 's/^[#[:space:]]*ListenAddress\s+.*/ListenAddress 0.0.0.0/' /etc/ssh/sshd_config \
  && sed -ri 's/^[#[:space:]]*PubkeyAuthentication\s+.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
  && sed -ri 's/^[#[:space:]]*PermitRootLogin\s+.*/PermitRootLogin yes/' /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config \
  && apt clean \
  && rm -rf /var/lib/apt/lists/*

# Copy compiled PostgreSQL binaries and extensions from the build stage
COPY --from=build /usr/local/pgsql /usr/local/pgsql

# Copy scws runtime libraries and configure ldconfig
COPY --from=build /usr/local/lib/libscws.* /usr/local/lib/
RUN echo "/usr/local/lib" > /etc/ld.so.conf.d/usr-local-lib.conf \
  && ldconfig

COPY --from=uv-bin /uv /usr/local/bin/uv

RUN uv python install ${PYTHON_VERSION}

ENV PATH=/usr/local/pgsql/bin:${PATH}
ENV POSTGRES_ROOT=/pgdata
ENV POSTGRES_USER=dc_admin
ENV POSTGRES_DB=dc_db

RUN groupadd -r postgres && useradd -r -g postgres postgres

ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
RUN chmod +x /tini

COPY docker/postgres_config.sh /opt/dc-postgres/docker/postgres_config.sh
COPY docker/entrypoint.sh /opt/dc-postgres/docker/entrypoint.sh

RUN chmod +x \
  /opt/dc-postgres/docker/postgres_config.sh \
  /opt/dc-postgres/docker/entrypoint.sh

ENTRYPOINT ["/tini", "--", "/opt/dc-postgres/docker/entrypoint.sh"]
