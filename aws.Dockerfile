FROM amazonlinux:2023.5.20240819.0 AS base

SHELL ["/bin/bash", "-c"]

ENV GOSU_VERSION=1.17 \
    NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER="false" \
    DAEMON=false \
    SILENT=false \
    USER=nodebb \
    UID=1000 \
    GID=1000 \
    TZ="Asia/Seoul" \
    PATH="/opt/mecab/bin:${PATH}"

RUN dnf install -y --setopt=install_weak_deps=False \
    nginx nginx-all-modules	\
    nodejs20 nodejs20-npm git wget \
    && dnf install -y --allowerasing gnupg2-full \
    && rm -rf /var/cache/dnf \
    && ln -s /usr/bin/node-20 /usr/bin/node \
    && ln -s /usr/bin/npm-20 /usr/bin/npm

RUN git clone --recurse-submodules -j8 --depth 1 https://github.com/NodeBB/NodeBB.git /usr/src/app/

RUN groupadd --gid ${GID} ${USER} \
    && useradd --uid ${UID} --gid ${GID} \
        --home-dir /usr/src/app/ \
        --shell /bin/bash ${USER} \
    && chown -R ${USER}:${USER} /usr/src/app/

WORKDIR /usr/src/app/

RUN dnf -y --setopt=install_weak_deps=False install findutils gzip tar

RUN find . -mindepth 1 -maxdepth 1 -name '.*' ! -name '.' ! -name '..' -exec bash -c 'echo "Deleting {}"; rm -rf {}' \; \
  && rm -rf install/docker/entrypoint.sh \
  && rm -rf docker-compose.yml \
  && rm -rf Dockerfile \
  && cp /usr/src/app/install/package.json /usr/src/app/package.json

RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
  npm install \
    @nodebb/nodebb-plugin-reactions \
    nodebb-plugin-adsense \
    nodebb-plugin-extended-markdown \
    nodebb-plugin-question-and-answer \
    nodebb-plugin-sso-github \
    https://github.com/NavyStack/nodebb-plugin-dbsearch-korean.git  

ENV TINI_VERSION v0.19.0
RUN rpmArch="$(rpm --query --queryformat='%{ARCH}' rpm)" && \
    case "$rpmArch" in \
        aarch64) dpkgArch='arm64' ;; \
        x86_64) dpkgArch='amd64' ;; \
        *) echo >&2 "error: unsupported architecture '$rpmArch'"; exit 1 ;; \
    esac && \
    # Download and verify Tini
    wget https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-$dpkgArch -O /tini && \
    wget https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini-$dpkgArch.asc -O /tini.asc && \
    dnf install -y gnupg wget tar && \
    gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 595E85A6B1B4779EA4DAAEC70B588DFF0527A9B7 && \
    gpg --batch --verify /tini.asc /tini && \
    chmod +x /tini && \
    rm /tini.asc && \
    case "$rpmArch" in \
        aarch64) mecabArch='aarch64' ;; \
        x86_64) mecabArch='x86_64' ;; \
        *) echo >&2 "error: unsupported architecture '$rpmArch'"; exit 1 ;; \
    esac && \
    mecabKoUrl="https://github.com/Pusnow/mecab-ko-msvc/releases/download/release-0.999/mecab-ko-linux-${mecabArch}.tar.gz" && \
    mecabKoDicUrl="https://github.com/Pusnow/mecab-ko-msvc/releases/download/release-0.999/mecab-ko-dic.tar.gz" && \
    wget "${mecabKoUrl}" -O - | tar -xzvf - -C /opt && \
    wget "${mecabKoDicUrl}" -O - | tar -xzvf - -C /opt/mecab/share

FROM amazonlinux:2023.5.20240819.0 AS final

ENV GOSU_VERSION=1.17 \
    NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER="false" \
    DAEMON=false \
    SILENT=false \
    USER=nodebb \
    UID=1000 \
    GID=1000 \
    TZ="Asia/Seoul" \
    PATH="/opt/mecab/bin:${PATH}"

RUN dnf install -y --setopt=install_weak_deps=False \
    nginx nginx-all-modules	\
    nodejs20 nodejs20-npm git wget \
    && dnf install -y --allowerasing gnupg2-full \
    && rm -rf /var/cache/dnf \
    && ln -s /usr/bin/node-20 /usr/bin/node \
    && ln -s /usr/bin/npm-20 /usr/bin/npm

RUN groupadd --gid ${GID} ${USER} \
    && useradd --uid ${UID} --gid ${GID} \
        --home-dir /usr/src/app/ \
        --shell /bin/bash ${USER} \
    && chown -R ${USER}:${USER} /usr/src/app/

RUN set -eux; \
	\
	rpmArch="$(rpm --query --queryformat='%{ARCH}' rpm)"; \
	case "$rpmArch" in \
		aarch64) dpkgArch='arm64' ;; \
		armv[67]*) dpkgArch='armhf' ;; \
		i[3456]86) dpkgArch='i386' ;; \
		ppc64le) dpkgArch='ppc64el' ;; \
		riscv64 | s390x) dpkgArch="$rpmArch" ;; \
		x86_64) dpkgArch='amd64' ;; \
		*) echo >&2 "error: unknown/unsupported architecture '$rpmArch'"; exit 1 ;; \
	esac; \
	wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	\
# verify the signature
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	\
	chmod +x /usr/local/bin/gosu; \
# verify that the binary works
	gosu --version; \
	gosu nobody true

COPY nginx /etc/nginx
COPY --link --from=base /tini /usr/bin/tini
COPY --link --from=base /opt/mecab/ /opt/mecab/
COPY --link --from=base /usr/src/app/ /usr/src/app/
COPY --link --from=base /usr/src/app/install/docker/setup.json /usr/src/app/setup.json
COPY scripts/start.sh /usr/local/bin/

WORKDIR /usr/src/app/
STOPSIGNAL SIGQUIT
ENTRYPOINT [ "tini", "--", "start.sh" ]
