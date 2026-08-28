#!/usr/bin/env bash

set -e

# Clean up
rm -rf /var/lib/apt/lists/*

GCLOUD_VERSION=${VERSION:-"latest"}

# NOTE: devcontainer feature option resolution uppercases the option name
# (`installGkeGcloudAuthPlugin` -> `INSTALLGKEGCLOUDAUTHPLUGIN`). The upstream
# dhoeric feature reads `INSTALL_GKEGCLOUDAUTH_PLUGIN` (with an underscore),
# which is never set, so the option silently does nothing there. We read the
# correctly-named variable; fall back to the underscore form for safety.
INSTALL_GKE_GCLOUD_AUTH_PLUGIN="${INSTALLGKEGCLOUDAUTHPLUGIN:-${INSTALL_GKE_GCLOUD_AUTH_PLUGIN:-"false"}}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e 'Script must be run as root. Use sudo, su, or add "USER root" to your Dockerfile before running this script.'
    exit 1
fi

apt_get_update()
{
    echo "Running apt-get update..."
    apt-get update -y
}

# Checks if packages are installed and installs them if not
check_packages() {
    if ! dpkg -s "$@" > /dev/null 2>&1; then
        if [ "$(find /var/lib/apt/lists/* | wc -l)" = "0" ]; then
            apt_get_update
        fi
        apt-get -y install --no-install-recommends "$@"
    fi
}

export DEBIAN_FRONTEND=noninteractive

# Soft version matching that resolves a version for a given package in the *current apt-cache*
# Return value is stored in first argument (the unprocessed version)
apt_cache_version_soft_match() {

    # Version
    local variable_name="$1"
    local requested_version=${!variable_name}
    # Package Name
    local package_name="$2"

    # Ensure we've exported useful variables
    . /etc/os-release
    local architecture="$(dpkg --print-architecture)"

    dot_escaped="${requested_version//./\\.}"
    dot_plus_escaped="${dot_escaped//+/\\+}"
    # Regex needs to handle debian package version number format: https://www.systutorials.com/docs/linux/man/5-deb-version/
    version_regex="^(.+:)?${dot_plus_escaped}([\\.\\+ ~:-]|$)"
    set +e # Don't exit if finding version fails - handle gracefully
        # NOTE: trim trailing whitespace as well as leading -- `apt-cache madison`
        # pads its columns, and a trailing space in the resolved version silently
        # breaks any *quoted* `pkg=${VERSION}` use below.
        fuzzy_version="$(apt-cache madison ${package_name} | awk -F"|" '{print $2}' | sed -e 's/^[ \t]*//' -e 's/[ \t]*$//' | grep -E -m 1 "${version_regex}")"
    set -e
    if [ -z "${fuzzy_version}" ]; then
        echo "(!) No full or partial for package \"${package_name}\" match found in apt-cache for \"${requested_version}\" on OS ${ID} ${VERSION_CODENAME} (${architecture})."
        echo "Available versions:"
        apt-cache madison ${package_name} | awk -F"|" '{print $2}' | grep -oP '^(.+:)?\K.+'
        exit 1 # Fail entire script
    fi

    # Globally assign fuzzy_version to this value
    # Use this value as the return value of this function
    declare -g ${variable_name}="=${fuzzy_version}"
    echo "${variable_name} ${!variable_name}"
}

install_using_apt() {
    # Install dependencies
    check_packages apt-transport-https curl ca-certificates gnupg python3
    # Import key.
    # NOTE: the upstream `ghcr.io/dhoeric/features/google-cloud-cli` feature uses
    # `apt-key` here, which was removed in Debian 13 (trixie) / Ubuntu 24.04.
    # `gpg --dearmor` is the modern replacement (see dhoeric/features#36).
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list
    apt_get_update

    if [ "${GCLOUD_VERSION}" = "latest" ]; then
        # Empty, meaning grab the "latest" in the apt repo
        GCLOUD_VERSION=""
    else
        # Sets GCLOUD_VERSION to our desired version, if match found.
        apt_cache_version_soft_match GCLOUD_VERSION "google-cloud-cli"
        if [ "$?" != 0 ]; then
            return 1
        fi
    fi

    if ! (apt-get install -yq google-cloud-cli${GCLOUD_VERSION}); then
        rm -f /etc/apt/sources.list.d/google-cloud-sdk.list
        return 1
    fi

    # Install gke-gcloud-auth-plugin if needed
    if [ "${INSTALL_GKE_GCLOUD_AUTH_PLUGIN}" = "true" ]; then
        echo "(*) Installing 'gke-gcloud-auth-plugin' plugin..."
        # NOTE: Google renamed the `google-cloud-sdk-*` packages to
        # `google-cloud-cli-*`, and the transitional `google-cloud-sdk-` names have
        # since been dropped from the apt repo entirely. Installing the old name now
        # fails with "Package 'google-cloud-sdk-gke-gcloud-auth-plugin' has no
        # installation candidate".
        local plugin_package="google-cloud-cli-gke-gcloud-auth-plugin"

        # The plugin ships in lockstep with `google-cloud-cli` (same version numbers,
        # and no dependency between the two), so it takes the same pin resolved above
        # -- empty when the user asked for "latest".
        if ! (apt-get install -yq "${plugin_package}${GCLOUD_VERSION}"); then
            # Google's apt repo only keeps a rolling window of versions. If the pinned
            # plugin build is ever missing, prefer a version-skewed plugin over failing
            # the whole build.
            if [ -z "${GCLOUD_VERSION}" ]; then
                return 1
            fi
            echo "(!) No ${plugin_package}${GCLOUD_VERSION} in the apt repo, falling back to the latest plugin."
            if ! (apt-get install -yq "${plugin_package}"); then
                return 1
            fi
        fi
    fi
}

echo "(*) Installing google-cloud CLI..."
. /etc/os-release

# Install
install_using_apt

# Clean up
rm -rf /var/lib/apt/lists/*

echo "Done!"
