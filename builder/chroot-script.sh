#!/bin/bash
set -ex

# save HYPRIOT_* content from /etc/os-release. Needs to be done in
# case base-files gets updated during build
< /etc/os-release grep HYPRIOT_ > /tmp/os-release.add

KEYSERVER="ha.pool.sks-keyservers.net"

function clean_print(){
  local fingerprint="${2}"
  local func="${1}"

  nospaces=${fingerprint//[:space:]/}
  tolowercase=${nospaces,,}
  KEYID_long=${tolowercase:(-16)}
  KEYID_short=${tolowercase:(-8)}
  if [[ "${func}" == "fpr" ]]; then
    echo "${tolowercase}"
  elif [[ "${func}" == "long" ]]; then
    echo "${KEYID_long}"
  elif [[ "${func}" == "short" ]]; then
    echo "${KEYID_short}"
  elif [[ "${func}" == "print" ]]; then
    if [[ "${fingerprint}" != "${nospaces}" ]]; then
      printf "%-10s %50s\n" fpr: "${fingerprint}"
    fi
    # if [[ "${nospaces}" != "${tolowercase}" ]]; then
    #   printf "%-10s %50s\n" nospaces: $nospaces
    # fi
    if [[ "${tolowercase}" != "${KEYID_long}" ]]; then
      printf "%-10s %50s\n" lower: "${tolowercase}"
    fi
    printf "%-10s %50s\n" long: "${KEYID_long}"
    printf "%-10s %50s\n" short: "${KEYID_short}"
    echo ""
  else
    echo "usage: function {print|fpr|long|short} GPGKEY"
  fi
}


function get_gpg(){
  GPG_KEY="${1}"
  KEY_URL="${2}"

  clean_print print "${GPG_KEY}"
  GPG_KEY=$(clean_print fpr "${GPG_KEY}")

  if [[ "${KEY_URL}" =~ ^https?://* ]]; then
    echo "loading key from url"
    KEY_FILE=temp.gpg.key
    wget -q -O "${KEY_FILE}" "${KEY_URL}" --progress=bar:force 2>&1 | showProgressBar
  elif [[ -z "${KEY_URL}" ]]; then
    echo "no source given try to load from key server"
#    gpg --keyserver "${KEYSERVER}" --recv-keys "${GPG_KEY}"
    apt-key adv --keyserver "${KEYSERVER}" --recv-keys "${GPG_KEY}"
    return $?
  else
    echo "keyfile given"
    KEY_FILE="${KEY_URL}"
  fi

  FINGERPRINT_OF_FILE=$(gpg --with-fingerprint --with-colons "${KEY_FILE}" | grep fpr | rev |cut -d: -f2 | rev)

  if [[ ${#GPG_KEY} -eq 16 ]]; then
    echo "compare long keyid"
    CHECK=$(clean_print long "${FINGERPRINT_OF_FILE}")
  elif [[ ${#GPG_KEY} -eq 8 ]]; then
    echo "compare short keyid"
    CHECK=$(clean_print short "${FINGERPRINT_OF_FILE}")
  else
    echo "compare fingerprint"
    CHECK=$(clean_print fpr "${FINGERPRINT_OF_FILE}")
  fi

  if [[ "${GPG_KEY}" == "${CHECK}" ]]; then
    echo "key OK add to apt"
    apt-key add "${KEY_FILE}"
    rm -f "${KEY_FILE}"
    return 0
  else
    echo "key invalid"
    exit 1
  fi
}

## examples:
# clean_print {print|fpr|long|short} {GPGKEYID|FINGERPRINT}
# get_gpg {GPGKEYID|FINGERPRINT} [URL|FILE]

# device specific settings
HYPRIOT_DEVICE="ODROID C2"

# set up /etc/resolv.conf
DEST=$(readlink -m /etc/resolv.conf)
export DEST
mkdir -p "$(dirname "${DEST}")"
echo "nameserver 8.8.8.8" > "${DEST}"

# set up debian jessie backports
echo "deb http://httpredir.debian.org/debian jessie-backports main" > /etc/apt/sources.list.d/jessie-backports.list

# set up ODROID repository
ODROID_KEY_ID=AB19BAC9
get_gpg $ODROID_KEY_ID
echo "deb http://deb.odroid.in/c2/ xenial main" > /etc/apt/sources.list.d/odroid.list

# set up hypriot arm repository for odroid packages
PACKAGECLOUD_FPR=418A7F2FB0E1E6E7EABF6FE8C2E73424D59097AB
PACKAGECLOUD_KEY_URL=https://packagecloud.io/gpg.key
get_gpg "${PACKAGECLOUD_FPR}" "${PACKAGECLOUD_KEY_URL}"

# set up hypriot schatzkiste repository for generic packages
echo 'deb https://packagecloud.io/Hypriot/Schatzkiste/debian/ jessie main' >> /etc/apt/sources.list.d/hypriot.list

# add armhf as additional architecure (see below)
dpkg --add-architecture armhf

LXC_RESULT="$(dpkg-query -l lxc || echo Non-existent)"
#echo "************************ LXC_RESULT : $LXC_RESULT ************************"

# if there is no existing LXC then install all the packages.
if [[ $LXC_RESULT == "Non-existent" ]]; then
  echo $LXC_RESULT
else
  echo "************************ LXC exists already no need to install it ************************"
fi

# if there is no existing LXC then install all the packages.
if [[ ! -e "/installed" ]]; then
# define packages to install
packages=(
    # install xz tools
    xz-utils
    # as the Odroid C2 does not have a hardware clock we need a fake one
    fake-hwclock

    # install device-init
    device-init:armhf=${DEVICE_INIT_VERSION}

    # install dependencies for docker-tools
    lxc
    aufs-tools
    cgroupfs-mount
    cgroup-bin
    apparmor
    libseccomp2
    libltdl7

    # required to install docker-compose
    python-pip
)

# update all apt repository lists
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get upgrade -y

apt-get -y install --no-install-recommends ${packages[*]}

touch /installed
fi

DOWNLOADS_PATH="/downloads"
# install docker-engine
#DOCKER_DEB=$(mktemp)
DOCKER_DEB_PATH="$DOWNLOADS_PATH/$DOCKER_FILENAME"
# download our base root file system
if [ ! -e "$DOCKER_DEB_PATH" ]; then
  wget -q -O "$DOCKER_DEB_PATH" "$DOCKER_DEB_URL" --progress=bar:force 2>&1 | showProgressBar
  echo "${DOCKER_DEB_CHECKSUM} ${DOCKER_DEB_PATH}" | sha256sum -c -
  dpkg -i "$DOCKER_DEB_PATH"
else
  echo "$DOCKER_DEB_PATH already exists no need to download again."
fi
#wget -q -O "$DOCKER_DEB" "$DOCKER_DEB_URL"
#echo "${DOCKER_DEB_CHECKSUM} ${DOCKER_DEB}" | sha256sum -c -
#dpkg -i "$DOCKER_DEB"

DOCKER_COMPOSE_RESULT="$(docker-compose -v || echo Non-existent)"
#echo "************************ DOCKER_COMPOSE_RESULT : $DOCKER_COMPOSE_RESULT ************************"
if [[ $DOCKER_COMPOSE_RESULT == "Non-existent" ]]; then
  # install docker-compose
  pip install docker-compose=="${DOCKER_COMPOSE_VERSION}"
fi

DOCKER_MACHINE_PATH="$DOWNLOADS_PATH/docker-machine-$(uname -s)-$(uname -m)"
# download our base root file system
if [ ! -e "$DOCKER_MACHINE_PATH" ]; then
  wget -q -O "$DOCKER_MACHINE_PATH" "https://github.com/docker/machine/releases/download/v${DOCKER_MACHINE_VERSION}/docker-machine-$(uname -s)-$(uname -m)" --progress=bar:force 2>&1 | showProgressBar
  cp "$DOCKER_MACHINE_PATH" /usr/local/bin/docker-machine
  chmod +x /usr/local/bin/docker-machine
else
  echo "$DOCKER_MACHINE_PATH already exists no need to download again."
fi
# install docker-machine
#curl -L "https://github.com/docker/machine/releases/download/v${DOCKER_MACHINE_VERSION}/docker-machine-$(uname -s)-$(uname -m)" > /usr/local/bin/docker-machine

# install linux kernel for Odroid C2
apt-get -y install \
    --no-install-recommends \
    u-boot-tools # Removed default kernel installation \
    #"linux-image-${KERNEL_VERSION}"

# install latest mainline 4.13 kernel
KERNEL_MAINLINE_FILE="linux-4.13.0-rc4-gx-130271-gabe3c92.tar.xz"
KERNEL_MAINLINE_URL="https://www.dropbox.com/sh/l751jmswzr2v6o2/AACr-5PQddmFrE8Lj-3Bhlnoa/$KERNEL_MAINLINE_FILE?dl=0"
KERNEL_PATH="$DOWNLOADS_PATH/$KERNEL_MAINLINE_FILE"
if [ ! -e "$KERNEL_PATH" ]; then
  wget -q -O "$KERNEL_PATH" $KERNEL_MAINLINE_URL --progress=bar:force 2>&1 | showProgressBar
  tar --numeric-owner -C / -xhpPJf $KERNEL_PATH
  cp /boot/mainline.boot.ini /boot/boot.ini
else
  echo "$KERNEL_MAINLINE_FILE already exists no need to download again."
fi

# Restore os-release additions
cat /tmp/os-release.add >> /etc/os-release

# cleanup APT cache and lists
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# set device label and version number
echo "HYPRIOT_DEVICE=\"$HYPRIOT_DEVICE\"" >> /etc/os-release
echo "HYPRIOT_IMAGE_VERSION=\"$HYPRIOT_IMAGE_VERSION\"" >> /etc/os-release
cp /etc/os-release /boot/os-release
