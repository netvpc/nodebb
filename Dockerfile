FROM node:lts-bookworm AS git

ENV TZ="Asia/Seoul"

WORKDIR /usr/src/app/

RUN apt-get update \
  && apt-get -y --no-install-recommends install tini

RUN git clone --recurse-submodules -j8 --depth 1 https://github.com/NodeBB/NodeBB.git .

RUN find . -mindepth 1 -maxdepth 1 -name '.*' ! -name '.' ! -name '..' -exec bash -c 'echo "Deleting {}"; rm -rf {}' \; \
  && rm -rf install/docker/entrypoint.sh \
  && rm -rf docker-compose.yml \
  && rm -rf Dockerfile
  ## && jq 'del(.resolutions)' install/package.json | sponge install/package.json

FROM node:lts-bookworm AS node_modules_touch

ENV NODE_ENV=production \
    TZ="Asia/Seoul"

WORKDIR /usr/src/app/

COPY --from=git /usr/src/app/install/package.json /usr/src/app/

RUN --mount=type=cache,id=npm-cache,target=/root/.npm \
  npm install \
    @nodebb/nodebb-plugin-reactions \
    nodebb-plugin-adsense \
    nodebb-plugin-extended-markdown \
    nodebb-plugin-meilisearch \
    nodebb-plugin-question-and-answer \
    nodebb-plugin-sso-github \
    https://github.com/navystack/nodebb-plugin-dbsearch-rsjieba.git \
  && npm install --package-lock-only --omit=dev \
  && npm update --save

FROM node:lts-bookworm-slim

ENV NGINX_VERSION=1.27.0
ENV NJS_VERSION=0.8.4
ENV NJS_RELEASE=2~bookworm
ENV PKG_RELEASE=2~bookworm

ENV NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER="false" \
    DAEMON=false \
    SILENT=false \
    USER=nginx \
    UID=1001 \
    GID=1001 \
    TZ="Asia/Seoul"

RUN set -x \
# create nginx user/group first, to be consistent throughout docker variants
    && groupadd --system --gid $GID ${USER} || true \
    && useradd --system --gid ${USER} --home-dir /usr/src/app/ --comment "nginx user" --shell /bin/bash --uid $UID ${USER} || true \
    && mkdir -p /usr/src/app/logs/ /opt/config/ \
    && chown -R ${USER}:${USER} /usr/src/app/ /opt/config/ \
    && apt-get update \
    && apt-get install --no-install-recommends --no-install-suggests -y gnupg1 ca-certificates \
    && \
    NGINX_GPGKEYS="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 8540A6F18833A80E9C1653A42FD21310B49F6B46 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3"; \
    NGINX_GPGKEY_PATH=/etc/apt/keyrings/nginx-archive-keyring.gpg; \
    export GNUPGHOME="$(mktemp -d)"; \
    found=''; \
    for NGINX_GPGKEY in $NGINX_GPGKEYS; do \
        for server in \
            hkp://keyserver.ubuntu.com:80 \
            pgp.mit.edu \
        ; do \
            echo "Fetching GPG key $NGINX_GPGKEY from $server"; \
            gpg1 --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$NGINX_GPGKEY" && found=yes && break; \
        done; \
        test -z "$found" && echo >&2 "error: failed to fetch GPG key $NGINX_GPGKEY" && exit 1; \
    done; \
    gpg1 --export "$NGINX_GPGKEYS" > "$NGINX_GPGKEY_PATH" ; \
    rm -rf "$GNUPGHOME"; \
    apt-get remove --purge --auto-remove -y gnupg1 && rm -rf /var/lib/apt/lists/* \
    && dpkgArch="$(dpkg --print-architecture)" \
    && nginxPackages=" \
        nginx=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-xslt=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-geoip=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-image-filter=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-njs=${NGINX_VERSION}+${NJS_VERSION}-${NJS_RELEASE} \
    " \
    && case "$dpkgArch" in \
        amd64|arm64) \
# arches officialy built by upstream
            echo "deb [signed-by=$NGINX_GPGKEY_PATH] https://nginx.org/packages/mainline/debian/ bookworm nginx" >> /etc/apt/sources.list.d/nginx.list \
            && apt-get update \
            ;; \
        *) \
# we're on an architecture upstream doesn't officially build for
# let's build binaries from the published source packages
            echo "deb-src [signed-by=$NGINX_GPGKEY_PATH] https://nginx.org/packages/mainline/debian/ bookworm nginx" >> /etc/apt/sources.list.d/nginx.list \
            \
# new directory for storing sources and .deb files
            && tempDir="$(mktemp -d)" \
            && chmod 777 "$tempDir" \
# (777 to ensure APT's "_apt" user can access it too)
            \
# save list of currently-installed packages so build dependencies can be cleanly removed later
            && savedAptMark="$(apt-mark showmanual)" \
            \
# build .deb files from upstream's source packages (which are verified by apt-get)
            && apt-get update \
            && apt-get build-dep -y $nginxPackages \
            && ( \
                cd "$tempDir" \
                && DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" \
                    apt-get source --compile $nginxPackages \
            ) \
# we don't remove APT lists here because they get re-downloaded and removed later
            \
# reset apt-mark's "manual" list so that "purge --auto-remove" will remove all build dependencies
# (which is done after we install the built packages so we don't have to redownload any overlapping dependencies)
            && apt-mark showmanual | xargs apt-mark auto > /dev/null \
            && { [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; } \
            \
# create a temporary local APT repo to install from (so that dependency resolution can be handled by APT, as it should be)
            && ls -lAFh "$tempDir" \
            && ( cd "$tempDir" && dpkg-scanpackages . > Packages ) \
            && grep '^Package: ' "$tempDir/Packages" \
            && echo "deb [ trusted=yes ] file://$tempDir ./" > /etc/apt/sources.list.d/temp.list \
# work around the following APT issue by using "Acquire::GzipIndexes=false" (overriding "/etc/apt/apt.conf.d/docker-gzip-indexes")
#   Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
#   ...
#   E: Failed to fetch store:/var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages  Could not open file /var/lib/apt/lists/partial/_tmp_tmp.ODWljpQfkE_._Packages - open (13: Permission denied)
            && apt-get -o Acquire::GzipIndexes=false update \
            ;; \
    esac \
    \
    && apt-get install --no-install-recommends --no-install-suggests -y \
                        $nginxPackages \
                        gettext-base \
                        curl \
    && apt-get remove --purge --auto-remove -y && rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list \
    \
# if we have leftovers from building, let's purge them (including extra, unnecessary build deps)
    && if [ -n "$tempDir" ]; then \
        apt-get purge -y --auto-remove \
        && rm -rf "$tempDir" /etc/apt/sources.list.d/temp.list; \
    fi \
# forward request and error logs to docker log collector
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
# create a docker-entrypoint.d directory
    && mkdir /docker-entrypoint.d

RUN chown -R $UID:$GID /var/cache/nginx \
    && chmod -R g+w /var/cache/nginx /var/log/nginx/ \
    && chown -R $UID:0 /etc/nginx \
    && chmod -R g+w /etc/nginx

WORKDIR /usr/src/app/

ENV GOSU_VERSION=1.17
RUN set -eux; \
  # save list of currently installed packages for later so we can clean up
      savedAptMark="$(apt-mark showmanual)"; \
      apt-get update; \
      apt-get install -y --no-install-recommends ca-certificates gnupg wget; \
      rm -rf /var/lib/apt/lists/*; \
      \
      dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
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
  # clean up fetch dependencies
      apt-mark auto '.*' > /dev/null; \
      [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
      apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
      \
      chmod +x /usr/local/bin/gosu; \
  # verify that the binary works
      gosu --version; \
      gosu nobody true
  
COPY --link --from=node_modules_touch /usr/src/app/ /usr/src/app/
COPY --link --from=git /usr/src/app/ /usr/src/app/
COPY --link --from=git /usr/src/app/install/docker/setup.json /usr/src/app/setup.json
COPY --link --from=git /usr/bin/tini /usr/bin/tini
COPY scripts/start.sh /usr/local/bin/

VOLUME ["/usr/src/app/node_modules", "/usr/src/app/build", "/usr/src/app/public/uploads", "/opt/config/"]

COPY nginx /etc/nginx
COPY scripts/nginx/docker-entrypoint.sh /
COPY scripts/nginx/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d
COPY scripts/nginx/15-local-resolvers.envsh /docker-entrypoint.d
COPY scripts/nginx/20-envsubst-on-templates.sh /docker-entrypoint.d
COPY scripts/nginx/30-tune-worker-processes.sh /docker-entrypoint.d
ENTRYPOINT [ "tini", "--", "/docker-entrypoint.sh" ]

EXPOSE 8080

STOPSIGNAL SIGQUIT

CMD ["start.sh"]
