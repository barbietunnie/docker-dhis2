# syntax=docker/dockerfile:1.4


################################################################################


# Setting "ARG"s before the first "FROM" allows for the values to be used in any "FROM" value below.
# ARG values can be overridden with command line arguments at build time.
#
# Default for dhis2 image.
ARG BASE_IMAGE="docker.io/library/tomcat:9-jre11-openjdk-slim-bullseye"


################################################################################


# gosu for easy step-down from root - https://github.com/tianon/gosu/releases
# Using rust:bullseye (same as wait-builder stage) to have gpg, unzip, and wget preinstalled.
FROM docker.io/library/rust:1.61.0-bullseye as gosu-builder
ARG GOSU_VERSION=1.14
WORKDIR /work
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
dpkgArch="$(dpkg --print-architecture | awk -F'-' '{print $NF}')"
wget --no-verbose --output-document=gosu "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${dpkgArch}"
wget --no-verbose --output-document=gosu.asc "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${dpkgArch}.asc"
gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4
gpg --batch --verify gosu.asc gosu
chmod --changes 0755 gosu
./gosu --version
./gosu nobody true
EOF


################################################################################


# remco for building configuration files from templates - https://github.com/HeavyHorst/remco
# Using same verion of golang as shown in the output of `remco -version` from the released amd64 binary.
# REMCO_VERSION_GIT_COMMIT_HASH is used when the "Git Commit Hash" value from `remco -version` is
# different than the commit hash from the git tag for REMCO_VERSION.
FROM docker.io/library/golang:1.18.0-bullseye as remco-builder
ARG REMCO_VERSION=0.12.3
ARG REMCO_VERSION_GIT_COMMIT_HASH=7187ac836b62dd2af5eb14909ed343d7021b3a17
WORKDIR /work
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
dpkgArch="$(dpkg --print-architecture | awk -F'-' '{print $NF}')"
if [ "$dpkgArch" = "amd64" ]; then
  apt-get update
  apt-get install --yes --no-install-recommends unzip
  wget --no-verbose --output-document=remco_linux.zip "https://github.com/HeavyHorst/remco/releases/download/v${REMCO_VERSION}/remco_${REMCO_VERSION}_linux_${dpkgArch}.zip"
  unzip remco_linux.zip
  mv --verbose remco_linux remco
  chmod --changes 0755 remco
else
  git clone https://github.com/HeavyHorst/remco.git source
  cd source
  if [ -n "${REMCO_VERSION_GIT_COMMIT_HASH:-}" ]; then
    git checkout "$REMCO_VERSION_GIT_COMMIT_HASH"
  else
    git checkout "v${REMCO_VERSION}"
  fi
  make
  install --verbose --mode=0755 ./bin/remco ..
  cd ..
fi
./remco -version
EOF


################################################################################


# wait pauses until remote hosts are available - https://github.com/ufoscout/docker-compose-wait
# Tests are excluded due to the time taken running in arm64 emulation; see https://github.com/ufoscout/docker-compose-wait/issues/54
FROM docker.io/library/rust:1.61.0-bullseye as wait-builder
ARG WAIT_VERSION=2.9.0
WORKDIR /work
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
dpkgArch="$(dpkg --print-architecture | awk -F'-' '{print $NF}')"
if [ "$dpkgArch" = "amd64" ]; then
  wget --no-verbose "https://github.com/ufoscout/docker-compose-wait/releases/download/${WAIT_VERSION}/wait"
  chmod --changes 0755 wait
else
  git clone https://github.com/ufoscout/docker-compose-wait.git source
  cd source
  git checkout "$WAIT_VERSION"
  R_TARGET="$( rustup target list --installed | grep -- '-gnu' | tail -1 | awk '{print $1}'| sed 's/gnu/musl/' )"
  rustup target add "$R_TARGET"
  ####
  #### BEGIN crates.io update failure workaround
  #### https://users.rust-lang.org/t/updating-crates-io-index-manually/39360
  #### https://stackoverflow.com/a/9237511
  ####
    CARGO_CRATES_INDEX="${CARGO_HOME:-$HOME/.cargo}/registry/index/github.com-1ecc6299db9ec823/.git"
    git clone --bare https://github.com/rust-lang/crates.io-index.git "$CARGO_CRATES_INDEX"
    git --git-dir="$CARGO_CRATES_INDEX" fetch
    touch --reference="$CARGO_CRATES_INDEX/FETCH_HEAD" "${CARGO_CRATES_INDEX%git}last-updated"
  ####
  #### END crates.io update failure workaround
  ####
  cargo fetch --target="$R_TARGET"
  #cargo test --target="$R_TARGET"
  cargo build --target="$R_TARGET" --release
  strip ./target/"$R_TARGET"/release/wait
  install --verbose --mode=0755 ./target/"$R_TARGET"/release/wait ..
  cd ..
fi
./wait
EOF


################################################################################


# Tomcat with OpenJDK - https://hub.docker.com/_/tomcat (see "ARG BASE_IMAGE" above)
FROM "$BASE_IMAGE" as dhis2

# Install dependencies for dhis2-init.sh tasks, docker-entrypoint.sh, and general debugging
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
apt-get update
apt-get install --yes --no-install-recommends bind9-dnsutils curl gpg netcat-traditional python3 unzip wget zip
echo "deb http://apt.postgresql.org/pub/repos/apt $( awk -F'=' '/^VERSION_CODENAME/ {print $NF}' /etc/os-release )-pgdg main" > /etc/apt/sources.list.d/pgdg.list
curl --silent https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/apt.postgresql.org.gpg
apt-get update
apt-get install --yes --no-install-recommends postgresql-client
rm --recursive --force /var/lib/apt/lists/*
EOF

# Add tools from other build stages
COPY --chmod=755 --chown=root:root --from=gosu-builder /work/gosu /usr/local/bin/
COPY --chmod=755 --chown=root:root --from=remco-builder /work/remco /usr/local/bin/
COPY --chmod=755 --chown=root:root --from=wait-builder /work/wait /usr/local/bin/

# Create tomcat system user, disable crons, and clean up
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
adduser --system --disabled-password --group tomcat
echo 'tomcat' >> /etc/cron.deny
echo 'tomcat' >> /etc/at.deny
rm --verbose --force '/etc/.pwd.lock' '/etc/group-' '/etc/gshadow-' '/etc/passwd-' '/etc/shadow-'
EOF

# Set Tomcat permissions for tomcat user and group and clean up
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
for TOMCAT_DIR in 'conf/Catalina' 'logs' 'temp' 'work'; do
  mkdir --verbose --parents "/usr/local/tomcat/$TOMCAT_DIR"
  chmod --changes 0750 "/usr/local/tomcat/$TOMCAT_DIR"
  chown --recursive tomcat:tomcat "/usr/local/tomcat/$TOMCAT_DIR"
done
rm --verbose --recursive --force /tmp/hsperfdata_root /usr/local/tomcat/temp/safeToDelete.tmp
EOF

# Tomcat Lifecycle Listener to shutdown catalina on startup failures (https://github.com/ascheman/tomcat-lifecyclelistener)
ADD --chmod=644 --chown=root:root https://repo.maven.apache.org/maven2/net/aschemann/tomcat/tomcat-lifecyclelistener/1.0.1/tomcat-lifecyclelistener-1.0.1.jar /usr/local/tomcat/lib/tomcat-lifecyclelistener.jar
COPY --chmod=644 --chown=root:root ./tomcat/context.xml /usr/local/tomcat/conf/
COPY --chmod=644 --chown=root:root ./tomcat/setenv.sh /usr/local/tomcat/bin/

# Tomcat server configuration
COPY --chmod=644 --chown=root:root ./tomcat/server.xml /usr/local/tomcat/conf/

# Create DHIS2_HOME and set ownership for tomcat user and group (DHIS2 throws an error if /opt/dhis2 is not writable)
RUN <<EOF
#!/usr/bin/env bash
set -euxo pipefail
mkdir --verbose --parents /opt/dhis2
chown --changes tomcat:tomcat /opt/dhis2
EOF

# Add dhis2-init.sh and bundled scripts
COPY --chmod=755 --chown=root:root ./dhis2-init.sh /usr/local/bin/
COPY --chmod=755 --chown=root:root ./dhis2-init.d/10_dhis2-database.sh /usr/local/share/dhis2-init.d/
COPY --chmod=755 --chown=root:root ./dhis2-init.d/15_pgstatstatements.sh /usr/local/share/dhis2-init.d/
COPY --chmod=755 --chown=root:root ./dhis2-init.d/20_dhis2-initwar.sh /usr/local/share/dhis2-init.d/

# Add image helper scripts
COPY --chmod=755 --chown=root:root ./helpers/db-empty.sh /usr/local/bin/
COPY --chmod=755 --chown=root:root ./helpers/db-export.sh /usr/local/bin/
COPY --chmod=755 --chown=root:root ./helpers/port-from-url.py /usr/local/bin/

# remco configurations and templates
COPY --chmod=644 --chown=root:root ./remco/config.toml /etc/remco/config
COPY --chmod=644 --chown=root:root ./remco/dhis2-onetime.toml /etc/remco/
COPY --chmod=644 --chown=root:root ./remco/tomcat.toml /etc/remco/
COPY --chmod=644 --chown=root:root ./remco/templates/dhis2/dhis.conf.tmpl /etc/remco/templates/dhis2/
COPY --chmod=644 --chown=root:root ./remco/templates/tomcat/server.xml.tmpl /etc/remco/templates/tomcat/
# Initialize empty remco log file for the tomcat user (the "EOF" on the next line is not a typo)
COPY --chmod=644 --chown=tomcat:tomcat <<EOF /var/log/remco.log
EOF

# Add our own entrypoint for initialization
COPY --chmod=755 --chown=root:root docker-entrypoint.sh /usr/local/bin/
ENTRYPOINT ["docker-entrypoint.sh"]

# Remco will create configuration files and start Tomcat
CMD ["remco"]

# Extract the dhis.war file alongside this Dockerfile, and mitigate Log4Shell on old versions
RUN --mount=type=bind,source=dhis.war,target=dhis.war <<EOF
#!/usr/bin/env bash
set -euxo pipefail
# Extract the contents of dhis.war to webapps/ROOT/
unzip -qq dhis.war -d /usr/local/tomcat/webapps/ROOT
# Extract build.properties to /opt/dhis2/
find /usr/local/tomcat/webapps/ROOT/WEB-INF/lib/ -name 'dhis-service-core-2.*.jar' -exec unzip -p '{}' build.properties \; | tee /opt/dhis2/build.properties
# Remove vulnerable JndiLookup.class to mitigate Log4Shell
shopt -s globstar nullglob  # bash 4 required (SC2044)
for JAR in /usr/local/tomcat/webapps/**/log4j-core-2.*.jar ; do
  JAR_LOG4J_VERSION="$( unzip -p "$JAR" 'META-INF/maven/org.apache.logging.log4j/log4j-core/pom.properties' | awk -F'=' '/^version=/ {print $NF}' )"
  if [ "2.16.0" != "$( echo -e "2.16.0\n$JAR_LOG4J_VERSION" | sort --version-sort | head --lines='1' )" ]; then
    set +o pipefail
    if unzip -l "$JAR" | grep --quiet 'JndiLookup.class' ; then
      zip --delete "$JAR" 'org/apache/logging/log4j/core/lookup/JndiLookup.class' | grep --invert-match 'zip warning'
    fi
    set -o pipefail
  fi
done
EOF
