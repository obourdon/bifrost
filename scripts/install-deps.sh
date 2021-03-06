#!/bin/bash
set -eux

declare -A PKG_MAP

# workaround: for latest bindep to work, it needs to use en_US local
export LANG=c

# Lets use python3 by default
USE_PYTHON3=${USE_PYTHON3:-true}


CHECK_CMD_PKGS=(
    gcc
    libffi
    libopenssl
    lsb-release
    make
    net-tools
    python-devel
    python
    venv
    wget
)

function get_pip () {
    if [ ! $(which $1) ]; then
        wget -O /tmp/get-pip.py https://bootstrap.pypa.io/3.2/get-pip.py
        sudo -H -E ${PYTHON} /tmp/get-pip.py
    fi
    PIP=$(which $1)
}

source /etc/os-release || source /usr/lib/os-release
case ${ID,,} in
    *suse)
    OS_FAMILY="Suse"
    INSTALLER_CMD="sudo -H -E zypper install -y --no-recommends"
    CHECK_CMD="zypper search --match-exact --installed"
    PKG_MAP=(
        [gcc]=gcc
        [libffi]=libffi-devel
        [libopenssl]=libopenssl-devel
        [lsb-release]=lsb-release
        [make]=make
        [net-tools]=net-tools
        [python]=python
        [python-devel]=python-devel
        [venv]=python-virtualenv
        [wget]=wget
    )
    EXTRA_PKG_DEPS=( python-xml )
    sudo zypper -n ref
    # NOTE (cinerama): we can't install python without removing this package
    # if it exists
    if $(${CHECK_CMD} patterns-openSUSE-minimal_base-conflicts &> /dev/null); then
        sudo -H zypper remove -y patterns-openSUSE-minimal_base-conflicts
    fi
    ;;

    ubuntu|debian)
    OS_FAMILY="Debian"
    export DEBIAN_FRONTEND=noninteractive
    INSTALLER_CMD="sudo -H -E apt-get -y install"
    CHECK_CMD="dpkg -l"
    if [[ ${USE_PYTHON3} =~ "true" ]]; then
        PKG_MAP=(
            [gcc]=gcc
            [libffi]=libffi-dev
            [libopenssl]=libssl-dev
            [lsb-release]=lsb-release
            [make]=make
            [net-tools]=net-tools
            [python]=python-minimal
            [python-devel]=libpython3-dev
            [venv]=python3-virtualenv
            [wget]=wget
        )
    else
        PKG_MAP=(
            [gcc]=gcc
            [libffi]=libffi-dev
            [libopenssl]=libssl-dev
            [lsb-release]=lsb-release
            [make]=make
            [net-tools]=net-tools
            [python]=python-minimal
            [python-devel]=libpython-dev
            [venv]=python-virtualenv
            [wget]=wget
        )
    fi
    EXTRA_PKG_DEPS=()
    sudo apt-get update
    ;;

    rhel|fedora|centos)
    OS_FAMILY="RedHat"
    PKG_MANAGER=$(which dnf || which yum)
    INSTALLER_CMD="sudo -H -E ${PKG_MANAGER} -y install"
    CHECK_CMD="rpm -q"
    PKG_MAP=(
        [gcc]=gcc
        [libffi]=libffi-devel
        [libopenssl]=openssl-devel
        [lsb-release]=redhat-lsb
        [make]=make
        [net-tools]=net-tools
        [python]=python
        [python-devel]=python-devel
        [venv]=python-virtualenv
        [wget]=wget
    )
    EXTRA_PKG_DEPS=()
    sudo yum updateinfo
    if $(grep -q Fedora /etc/redhat-release); then
        EXTRA_PKG_DEPS="python-dnf redhat-rpm-config"
    fi
    ;;

    *) echo "ERROR: Supported package manager not found.  Supported: apt, dnf, yum, zypper"; exit 1;;
esac

# If we're using a venv, we need to work around sudo not
# keeping the path even with -E.
if [[ ${USE_PYTHON3} =~ "true" ]]; then
    PYTHON=$(which python3)
    get_pip pip3
    VIRTUALENV_OPTS="-p python3"
else
    PYTHON=$(which python)
    get_pip pip
fi

# if running in OpenStack CI, then make sure epel is enabled
# since it may already be present (but disabled) on the host
if env | grep -q ^ZUUL; then
    if [[ -x '/usr/bin/yum' ]]; then
        ${INSTALLER_CMD} yum-utils
        sudo yum-config-manager --enable epel || true
    fi
fi

if ! $(${PYTHON} --version &>/dev/null); then
    ${INSTALLER_CMD} ${PKG_MAP[python]}
fi
if ! $(gcc -v &>/dev/null); then
    ${INSTALLER_CMD} ${PKG_MAP[gcc]}
fi
if ! $(wget --version &>/dev/null); then
    ${INSTALLER_CMD} ${PKG_MAP[wget]}
fi
if [ -n "${VENV-}" ]; then
    if ! $(${PYTHON} -m virtualenv --version &>/dev/null); then
        ${INSTALLER_CMD} ${PKG_MAP[venv]}
    fi
fi

for pkg in ${CHECK_CMD_PKGS[@]}; do
    if ! $(${CHECK_CMD} ${PKG_MAP[$pkg]} &>/dev/null); then
        ${INSTALLER_CMD} ${PKG_MAP[$pkg]}
    fi
done

if [ -n "${EXTRA_PKG_DEPS-}" ]; then
    for pkg in ${EXTRA_PKG_DEPS}; do
        if ! $(${CHECK_CMD} ${pkg} &>/dev/null); then
            ${INSTALLER_CMD} ${pkg}
        fi
    done
fi

if [ -n "${VENV-}" ]; then
    echo "NOTICE: Using virtualenv for this installation."
    if [ ! -f ${VENV}/bin/activate ]; then
        # only create venv if one doesn't exist
        eval sudo -H -E ${PYTHON} -m virtualenv --no-site-packages ${VENV} ${VIRTUALENV_OPTS:-""}
    fi
    # Note(cinerama): activate is not compatible with "set -u";
    # disable it just for this line.
    set +u
    . ${VENV}/bin/activate
    set -u
    VIRTUAL_ENV=${VENV}
else
    echo "NOTICE: Not using virtualenv for this installation."
fi

# To install python packages, we need pip.
#
# We can't use the apt packaged version of pip since
# older versions of pip are incompatible with
# requests, one of our indirect dependencies (bug 1459947).
#
# Note(cinerama): We use pip to install an updated pip plus our
# other python requirements. pip breakages can seriously impact us,
# so we've chosen to install/upgrade pip here rather than in
# requirements (which are synced automatically from the global ones)
# so we can quickly and easily adjust version parameters.
# See bug 1536627.
#

if [ ! -f ${PIP} ]; then
    wget -O /tmp/get-pip.py https://bootstrap.pypa.io/3.2/get-pip.py
    sudo -H -E ${PYTHON} /tmp/get-pip.py
fi

sudo -H -E ${PIP} install "pip>6.0"

# upgrade setuptools, as latest version is needed to install some projects
sudo -H -E ${PIP} install --upgrade --force setuptools

sudo -H -E ${PIP} install -r "$(dirname $0)/../requirements.txt"

# Install the rest of required packages using bindep
sudo -H -E ${PIP} install bindep

# bindep returns 1 if packages are missing
bindep -b &> /dev/null || ${INSTALLER_CMD} $(bindep -b)
