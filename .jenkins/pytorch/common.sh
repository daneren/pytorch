#!/bin/bash

# Common setup for all Jenkins scripts

# NB: define this function before set -x, so that we don't
# pollute the log with a premature EXITED_USER_LAND ;)
function cleanup {
  # Note that if you've exited user land, then CI will conclude that
  # any failure is the CI's fault.  So we MUST only output this
  # string
  retcode=$?
  set +x
  if [ $retcode -eq 0 ]; then
    echo "EXITED_USER_LAND"
  fi
}

set -ex

# Save the SCRIPT_DIR absolute path in case later we chdir (as occurs in the gpu perf test)
SCRIPT_DIR="$( cd "$(dirname "${BASH_SOURCE[0]}")" ; pwd -P )"

# Required environment variables:
#   $BUILD_ENVIRONMENT (should be set by your Docker image)

# Figure out which Python to use for ROCm
if [[ "${BUILD_ENVIRONMENT}" == *rocm* ]] && [[ "${BUILD_ENVIRONMENT}" =~ py((2|3)\.?[0-9]?\.?[0-9]?) ]]; then
  PYTHON=$(which "python${BASH_REMATCH[1]}")
  # non-interactive bashs do not expand aliases by default
  shopt -s expand_aliases
  export PYTORCH_TEST_WITH_ROCM=1
  alias python="$PYTHON"
  # temporary to locate some kernel issues on the CI nodes
  export HSAKMT_DEBUG_LEVEL=4
fi

# This token is used by a parser on Jenkins logs for determining
# if a failure is a legitimate problem, or a problem with the build
# system; to find out more, grep for this string in ossci-job-dsl.
echo "ENTERED_USER_LAND"

export IS_PYTORCH_CI=1

# compositional trap taken from https://stackoverflow.com/a/7287873/23845

# note: printf is used instead of echo to avoid backslash
# processing and to properly handle values that begin with a '-'.

log() { printf '%s\n' "$*"; }
error() { log "ERROR: $*" >&2; }
fatal() { error "$@"; exit 1; }

# appends a command to a trap
#
# - 1st arg:  code to add
# - remaining args:  names of traps to modify
#
trap_add() {
    trap_add_cmd=$1; shift || fatal "${FUNCNAME} usage error"
    for trap_add_name in "$@"; do
        trap -- "$(
            # helper fn to get existing trap command from output
            # of trap -p
            extract_trap_cmd() { printf '%s\n' "$3"; }
            # print existing trap command with newline
            eval "extract_trap_cmd $(trap -p "${trap_add_name}")"
            # print the new trap command
            printf '%s\n' "${trap_add_cmd}"
        )" "${trap_add_name}" \
            || fatal "unable to add to trap ${trap_add_name}"
    done
}
# set the trace attribute for the above function.  this is
# required to modify DEBUG or RETURN traps because functions don't
# inherit them unless the trace attribute is set
declare -f -t trap_add

trap_add cleanup EXIT

function assert_git_not_dirty() {
    # TODO: we should add an option to `build_amd.py` that reverts the repo to
    #       an unmodified state.
    if ([[ "$BUILD_ENVIRONMENT" != *rocm* ]] && [[ "$BUILD_ENVIRONMENT" != *xla* ]]) ; then
        git_status=$(git status --porcelain)
        if [[ $git_status ]]; then
            echo "Build left local git repository checkout dirty"
            echo "git status --porcelain:"
            echo "${git_status}"
            exit 1
        fi
    fi
}

if [[ "$BUILD_ENVIRONMENT" != *pytorch-win-* ]]; then
  if which sccache > /dev/null; then
    # Save sccache logs to file
    sccache --stop-server || true
    rm ~/sccache_error.log || true
    # increasing SCCACHE_IDLE_TIMEOUT so that extension_backend_test.cpp can build after this PR:
    # https://github.com/pytorch/pytorch/pull/16645
    SCCACHE_ERROR_LOG=~/sccache_error.log SCCACHE_IDLE_TIMEOUT=1200 RUST_LOG=sccache::server=error sccache --start-server

    # Report sccache stats for easier debugging
    sccache --zero-stats
    function sccache_epilogue() {
      echo '=================== sccache compilation log ==================='
      python "$SCRIPT_DIR/print_sccache_log.py" ~/sccache_error.log 2>/dev/null
      echo '=========== If your build fails, please take a look at the log above for possible reasons ==========='
      sccache --show-stats
      sccache --stop-server || true
    }
    trap_add sccache_epilogue EXIT
  fi

  if which ccache > /dev/null; then
    # Report ccache stats for easier debugging
    ccache --zero-stats
    ccache --show-stats
    function ccache_epilogue() {
      ccache --show-stats
    }
    trap_add ccache_epilogue EXIT
  fi
fi

# It's called a COMPACT_JOB_NAME because it's distinct from the
# Jenkin's provided JOB_NAME, which also includes a prefix folder
# e.g. pytorch-builds/

if [ -z "$COMPACT_JOB_NAME" ]; then
  echo "Jenkins build scripts must set COMPACT_JOB_NAME"
  exit 1
fi

if [[ "$BUILD_ENVIRONMENT" == *pytorch-linux-xenial-cuda10.1-cudnn7-py3* ]] || \
   [[ "$BUILD_ENVIRONMENT" == *pytorch-linux-trusty-py3.6-gcc7* ]] || \
   [[ "$BUILD_ENVIRONMENT" == *pytorch_macos* ]]; then
  BUILD_TEST_LIBTORCH=1
else
  BUILD_TEST_LIBTORCH=0
fi

# Use conda cmake in some CI build. Conda cmake will be newer than our supported
# min version (3.5 for xenial and 3.10 for bionic),
# so we only do it in four builds that we know should use conda.
# Linux bionic cannot find conda mkl with cmake 3.10, so we need a cmake from conda.
# Alternatively we could point cmake to the right place
# export CMAKE_PREFIX_PATH=${CONDA_PREFIX:-"$(dirname $(which conda))/../"}
if [[ "$BUILD_ENVIRONMENT" == *pytorch-xla-linux-bionic* ]] || \
   [[ "$BUILD_ENVIRONMENT" == *pytorch-linux-xenial-cuda9-cudnn7-py2* ]] || \
   [[ "$BUILD_ENVIRONMENT" == *pytorch-linux-xenial-cuda10.1-cudnn7-py3* ]] || \
   [[ "$BUILD_ENVIRONMENT" == *pytorch-linux-bionic* ]]; then
  if ! which conda; then
    echo "Expected ${BUILD_ENVIRONMENT} to use conda, but 'which conda' returns empty"
    exit 1
  else
    conda install -q -y cmake
  fi
fi
if which conda; then
  # MKL is provided via conda. Usually, users will activate their conda
  # environment before building a project, which will add LDFLAGS
  # (and much more). Without LDFLAGS, we get
  # "not found (try using -rpath or -rpath-link)"
  # errors when looking for MKL libraries while linking
  # Without the ldconfig conda-provided libs are not found at runtime
  if [[ "$BUILD_ENVIRONMENT" != *pytorch-win-* ]]; then
    CONDA_LIBS=${CONDA_PREFIX:-"$(dirname $(dirname $(which conda)))/lib"}
    export LDFLAGS="-Wl,-rpath-link=${CONDA_LIBS}"
    # TODO: once the new docker images in this PR (PR 37737) are created, this is
    # redundant (it should be part of .circleci/docker/common/install_conda.sh)
    if [ -e /etc/ld.so.conf.d/conda-python.conf ]; then
      echo Now safe to remove this temporary fix from .jenkins/pytorch/commmon.sh
    else
      echo Temporarily adding "${CONDA_LIBS}" to ldconfig
      sudo sh -c "echo ${CONDA_LIBS} > /etc/ld.so.conf.d/conda-python.conf"
      sudo ldconfig
    fi
  fi
  unset CONDA_LIBS
fi

function pip_install() {
  # retry 3 times
  # old versions of pip don't have the "--progress-bar" flag
  pip install --progress-bar off "$@" || pip install --progress-bar off "$@" || pip install --progress-bar off "$@" ||\
  pip install "$@" || pip install "$@" || pip install "$@"
}

function pip_uninstall() {
  # uninstall 2 times
  pip uninstall -y "$@" || pip uninstall -y "$@"
}

retry () {
  $*  || (sleep 1 && $*) || (sleep 2 && $*)
}

function get_exit_code() {
  set +e
  "$@"
  retcode=$?
  set -e
  return $retcode
}

function file_diff_from_base() {
  # The fetch may fail on Docker hosts, but it's not always necessary.
  set +e
  git fetch origin master --quiet
  set -e
  git diff --name-only "$(git merge-base origin/master HEAD)" > "$1"
}

function get_bazel() {
  # download bazel version
  wget https://github.com/bazelbuild/bazel/releases/download/3.1.0/bazel-3.1.0-linux-x86_64 -O tools/bazel
  # verify content
  echo '753434f4fa730266cf5ce21d1fdd425e1e167dd9347ad3e8adc19e8c0d54edca  tools/bazel' | sha256sum --quiet -c

  chmod +x tools/bazel
}
