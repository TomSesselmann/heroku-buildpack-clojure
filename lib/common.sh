#!/usr/bin/env bash

export BUILDPACK_STDLIB_URL="https://lang-common.s3.amazonaws.com/buildpack-stdlib/v7/stdlib.sh"

cache_copy() {
  rel_dir=$1
  from_dir=$2
  to_dir=$3
  rm -rf $to_dir/$rel_dir
  if [ -d $from_dir/$rel_dir ]; then
    mkdir -p $to_dir/$rel_dir
    cp -pr $from_dir/$rel_dir/. $to_dir/$rel_dir
  fi
}

get_os() {
  uname | tr '[:upper:]' '[:lower:]'
}

RESOLVE="$BP_DIR/vendor/resolve-version-$(get_os)"

resolve() {
  local binary="$1"
  local versionRequirement="$2"
  local n=0
  local output

  # retry this up to 5 times in case of spurious failed API requests
  until [ $n -ge 5 ]
  do
    # if a user sets the HTTP_PROXY ENV var, it could prevent this from making the S3 requests
    # it needs here. We can ignore this proxy for aws urls with NO_PROXY
    # see testAvoidHttpProxyVersionResolutionIssue test
    if output=$(NO_PROXY="amazonaws.com" $RESOLVE "$binary" "$versionRequirement"); then
      echo "$output"
      return 0
    # don't retry if we get a negative result
    elif [[ $output = "No result" ]]; then
      return 1
    elif [[ $output == "Could not parse"* ]] || [[ $output == "Could not get"* ]]; then
      return 1
    else
      n=$((n+1))
      # break for a second with a linear backoff
      sleep $((n+1))
    fi
  done

  return 1
}

# Install yarn
install_yarn() {
  local version="${1:?}"
  local dir="${2:?}"
  local number url code resolve_result

  echo "Resolving yarn version $version..."
  resolve_result=$(resolve yarn "$version" || echo "failed")

  if [[ "$resolve_result" == "failed" ]]; then
    local error

    # Allow the subcommand to fail without trapping the error so we can
    # get the failing message output
    set +e

    # re-request the result, saving off the reason for the failure this time
    error=$($RESOLVE yarn "$version")

    # re-enable trapping
    set -e
    
    if [[ $error = "No result" ]]; then
      echo "Could not find Yarn version corresponding to version requirement: $version"
    elif [[ $error == "Could not parse"* ]] || [[ $error == "Could not get"* ]]; then
      echo "Error: Invalid semantic version \"$version\""
    else
      echo "Error: Unknown error installing \"$version\" of yarn"
    fi
  fi

  read -r number url < <(echo "$resolve_result")

  echo "Downloading and installing yarn ($number)..."
  code=$(curl "$url" -L --silent --fail --retry 5 --retry-max-time 15 -o /tmp/yarn.tar.gz --write-out "%{http_code}")
  if [ "$code" != "200" ]; then
    echo "Unable to download yarn: $code" && false
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  # https://github.com/yarnpkg/yarn/issues/770
  if tar --version | grep -q 'gnu'; then
    tar xzf /tmp/yarn.tar.gz -C "$dir" --strip 1 --warning=no-unknown-keyword
  else
    tar xzf /tmp/yarn.tar.gz -C "$dir" --strip 1
  fi
  chmod +x "$dir"/bin/*
  echo "Installed yarn $(yarn --version)"
}

detect_and_install_yarn() {
  local buildDir=${1}
  if $YARN; then
    yarnVersion="1.x"
    echo "-----> Installing yarn ${yarnVersion}..."
    install_yarn ${yarnVersion} ${buildDir}/.heroku/yarn 2>&1 | sed -u 's/^/       /'
    export PATH=${buildDir}/.heroku/yarn/bin:$PATH
  fi
}

# Install node.js
install_nodejs() {
  local version="${1:?}"
  local dir="${2:?}"
  local os="linux"
  local cpu="x64"
  local platform="$os-$cpu"

  echo "Resolving node version $version..."
  if ! read number url < <(curl --silent --get --retry 5 --retry-max-time 15 --data-urlencode "range=$version" "https://nodebin.herokai.com/v1/node/$platform/latest.txt"); then
    local error=$(curl --silent --get --retry 5 --retry-max-time 15 --data-urlencode "range=$version" "https://nodebin.herokai.com/v1/node/$platform/latest.txt")
    if [[ $error = "No result" ]]; then
      echo "Could not find Node version corresponding to version requirement: $version";
    else
      echo "Error: Invalid semantic version \"$version\""
    fi
  fi

  echo "Downloading and installing node $version..."
  local code=$(curl "$url" -L --silent --fail --retry 5 --retry-max-time 15 -o /tmp/node.tar.gz --write-out "%{http_code}")
  if [ "$code" != "200" ]; then
    echo "Unable to download node: $code" && false
  fi
  tar xzf /tmp/node.tar.gz -C /tmp
  mv /tmp/node-v$version-$os-$cpu $dir
  chmod +x $dir/bin/*
}

detect_and_install_nodejs() {
  local buildDir=${1}
  if [ ! -d ${buildDir}/.heroku/nodejs ] && [ "true" != "$SKIP_NODEJS_INSTALL" ]; then
    if [ "$(grep lein-npm ${buildDir}/project.clj)" != "" ] || [ -n "$NODEJS_VERSION"  ]; then
      nodejsVersion=${NODEJS_VERSION:-4.2.1}
      echo "-----> Installing Node.js ${nodejsVersion}..."
      install_nodejs ${nodejsVersion} ${buildDir}/.heroku/nodejs 2>&1 | sed -u 's/^/       /'
      export PATH=${buildDir}/.heroku/nodejs/bin:$PATH
    fi
  fi
}

install_jdk() {
  local install_dir=${1}

  let start=$(nowms)
  JVM_COMMON_BUILDPACK=${JVM_COMMON_BUILDPACK:-https://buildpack-registry.s3.amazonaws.com/buildpacks/heroku/jvm.tgz}
  mkdir -p /tmp/jvm-common
  curl --retry 3 --silent --location $JVM_COMMON_BUILDPACK | tar xzm -C /tmp/jvm-common --strip-components=1
  source /tmp/jvm-common/bin/util
  source /tmp/jvm-common/bin/java
  source /tmp/jvm-common/opt/jdbc.sh
  mtime "jvm-common.install.time" "${start}"

  let start=$(nowms)
  install_java_with_overlay ${install_dir}
  mtime "jvm.install.time" "${start}"
}
