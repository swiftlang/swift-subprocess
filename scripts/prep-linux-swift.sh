#!/usr/bin/env bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift.org open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0 with Runtime Library Exception
##
## See https://swift.org/LICENSE.txt for license information
##
##===----------------------------------------------------------------------===##

# This script does a bit of extra preparation of the docker containers used to run the GitHub workflows
# that are specific to this project's needs when building/testing. Note that this script runs on
# every supported Linux distribution so it must adapt to the distribution that it is running.

if [[ "$(uname -s)" == "Linux" ]]; then
    # Install the basic utilities depending on the type of Linux distribution
    apt-get --help && apt-get update && TZ=Etc/UTC apt-get -y install curl make gpg tzdata
    yum --help && (curl --help && yum -y install curl) && yum -y install make gpg tar procps
fi

set -e

while [ $# -ne 0 ]; do
    arg="$1"
    case "$arg" in
        --install-swiftly)
            installSwiftly=true
            ;;
        --swift-snapshot)
            swiftSnapshot="$2"
            shift;
            ;;
        *)
            ;;
    esac
    shift
done

if [ "$installSwiftly" == true ]; then
    echo "Installing swiftly"

    curl -O "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" && tar zxf swiftly-*.tar.gz && ./swiftly init -y --skip-install
    # shellcheck source=/dev/null
    . "/root/.local/share/swiftly/env.sh"

    hash -r

    selector=()
    runSelector=()

    if [ "$swiftSnapshot" != "" ]; then
        echo "Installing latest $swiftSnapshot-snapshot toolchain"
        selector=("$swiftSnapshot-snapshot")
        runSelector=("+$swiftSnapshot-snapshot")
    elif [ -f .swift-version ]; then
        echo "Installing selected swift toolchain from .swift-version file"
        selector=()
        runSelector=()
    else
        echo "Installing latest toolchain"
        selector=("latest")
        runSelector=("+latest")
    fi

    TMPDIR=/var/tmp swiftly install --post-install-file=post-install.sh "${selector[@]}"

    if [ -f post-install.sh ]; then
        echo "Performing swift toolchain post-installation"
        chmod u+x post-install.sh && ./post-install.sh
    fi

    echo "Displaying swift version"
    swiftly run "${runSelector[@]}" swift --version
fi
