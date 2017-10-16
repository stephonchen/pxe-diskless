#!/bin/bash
set -e

WORK_DIR="$(mktemp --directory --tmpdir build-root.XXXXXXXX)"
UBUNTU_MIRROR="http://us.archive.ubuntu.com/ubuntu"
UBUNTU_SECURITY_MIRROR="http://security.ubuntu.com/ubuntu"
UBUNTU_VERSION="trusty"
ESSENTIAL_PACKAGES="dialog kmod ifupdown isc-dhcp-client net-tools iputils-ping unattended-upgrades curl iptables"

SUDO_USER="foobar"

export TERM=xterm-color
export LC_ALL=C

if [ "${UBUNTU_VERSION}" = "" ]; then
    echo "Please specify ubuntu distribution, e.g.: trusty, xenial, ..."
    exit
fi

trap 'rm -rf "${WORK_DIR}"' EXIT

debootstrap --arch=amd64 --variant=minbase "${UBUNTU_VERSION}" "${WORK_DIR}" "${UBUNTU_MIRROR}"

# Disable installation of recommended packages
echo 'APT::Install-Recommends "false";' >"${WORK_DIR}/etc/apt/apt.conf.d/50norecommends"
echo "deb ${UBUNTU_MIRROR} ${UBUNTU_VERSION} main restricted universe multiverse" > ${WORK_DIR}/etc/apt/sources.list
echo "deb ${UBUNTU_MIRROR} ${UBUNTU_VERSION}-updates main restricted universe multiverse" >> ${WORK_DIR}/etc/apt/sources.list
echo "deb ${UBUNTU_MIRROR} ${UBUNTU_VERSION}-backports main restricted universe multiverse" >> ${WORK_DIR}/etc/apt/sources.list
echo "deb ${UBUNTU_SECURITY_MIRROR} ${UBUNTU_VERSION}-security main restricted universe multiverse" >> ${WORK_DIR}/etc/apt/sources.list

echo "localhost" > ${WORK_DIR}/etc/hostname

cat > "${WORK_DIR}/init" <<'EOF'
#!/bin/sh

[ -d /dev ] || mkdir -m 0755 /dev
[ -d /root ] || mkdir -m 0700 /root
[ -d /sys ] || mkdir /sys
[ -d /proc ] || mkdir /proc
[ -d /tmp ] || mkdir /tmp
mkdir -p /var/lock
mount -t sysfs -o nodev,noexec,nosuid sysfs /sys
mount -t proc -o nodev,noexec,nosuid proc /proc
# Some things don't work properly without /etc/mtab.
ln -sf /proc/mounts /etc/mtab

grep -q '\<quiet\>' /proc/cmdline || echo "Loading, please wait..."

# Note that this only becomes /dev on the real filesystem if udev's scripts
# are used; which they will be, but it's worth pointing out
if ! mount -t devtmpfs -o mode=0755 udev /dev; then
        echo "W: devtmpfs not available, falling back to tmpfs for /dev"
        mount -t tmpfs -o mode=0755 udev /dev
        [ -e /dev/console ] || mknod -m 0600 /dev/console c 5 1
        [ -e /dev/null ] || mknod /dev/null c 1 3
fi
mkdir /dev/pts
mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts /dev/pts || true
mount -t tmpfs -o "noexec,nosuid,size=10%,mode=0755" tmpfs /run
mkdir /run/initramfs
# compatibility symlink for the pre-oneiric locations
ln -s /run/initramfs /dev/.initramfs

export MODPROBE_OPTIONS="-qb"

exec /sbin/init
EOF
chmod +x "${WORK_DIR}/init"

## Mount for depmod use
sync;sync;sync;
echo "phase 1"
mount -t sysfs -o nodev,noexec,nosuid sysfs "${WORK_DIR}/sys"
sleep 1
mount -t proc -o nodev,noexec,nosuid proc "${WORK_DIR}/proc"
sleep 1
mount -t devpts -o noexec,nosuid,gid=5,mode=0620 devpts "${WORK_DIR}/dev/pts"

echo "phase 2"
## Copy kernel lib to WORK_DIR
## Kernel version must match build machine's
chroot "${WORK_DIR}" apt-get update
chroot "${WORK_DIR}" apt-get -y --no-install-recommends install ${ESSENTIAL_PACKAGES}
cd /tmp
apt-get download linux-image-$(uname -r)
dpkg -x $(find . -maxdepth 1 -type f -name "linux-image-$(uname -r)*.deb" | head -n 1) linux-image-$(uname -r)
cp -af linux-image-$(uname -r)/lib ${WORK_DIR}/
cp -af linux-image-$(uname -r)/boot/vmlinuz-$(uname -r) /tmp/linux
rm -rf linux-image-$(uname -r)
sync;sync;sync
chroot "${WORK_DIR}" depmod

echo "phase 3"
# Implement insecurity
# remove password on root account
chroot "${WORK_DIR}" passwd -d root
chroot "${WORK_DIR}" apt-get -y upgrade
sed -i 's/pam_unix.so nullok_secure/pam_unix.so nullok/' "${WORK_DIR}/etc/pam.d/common-auth"

echo "phase 4"

umount -f "${WORK_DIR}/sys" "${WORK_DIR}/proc" "${WORK_DIR}/dev/pts"

# Clean up temporary files
chroot "${WORK_DIR}" apt-get -y --force-yes autoremove
chroot "${WORK_DIR}" apt-get -y --force-yes clean autoclean
rm -rf "${WORK_DIR}/var/cache/apt/*"
rm -rf "${WORK_DIR}/var/log/*"
rm -rf "${WORK_DIR}/usr/share/locale/*"
rm -rf "${WORK_DIR}/usr/share/man/*"
rm -rf "${WORK_DIR}/usr/share/doc/*"
rm -rf "${WORK_DIR}/var/log/*"
rm -rf "${WORK_DIR}/var/lib/apt/lists/*"
rm -rf "${WORK_DIR}/var/cache/*"

# Enable tty on COM2 (serial 1)
if [ "${UBUNTU_VERSION}" != "trusty" ]; then
    chroot "${WORK_DIR}" ln -sf "/lib/systemd/system/getty@.service" "/etc/systemd/system/getty.target.wants/getty@tty0.service"
    chroot "${WORK_DIR}" ln -sf "/lib/systemd/system/getty@.service" "/etc/systemd/system/getty.target.wants/getty@ttyS1.service"
else
    chroot "${WORK_DIR}" cp "/etc/init/tty1.conf" "/etc/init/tty0.conf"
    chroot "${WORK_DIR}" sed -i -e "s/tty1/tty0/g" "/etc/init/tty0.conf"
    chroot "${WORK_DIR}" cp "/etc/init/tty1.conf" "/etc/init/ttyS1.conf"
    chroot "${WORK_DIR}" sed -i -e "s/tty1/ttyS1/g" -e "s/38400/115200/g" "/etc/init/ttyS1.conf"
fi

# Configure networking
cat >> "${WORK_DIR}/etc/network/interfaces" <<'EOF'
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

EOF

# Load necessary modules
if [ "${UBUNTU_VERSION}" != "trusty" ]; then
    cat > "${WORK_DIR}/etc/modules-load.d/custom.conf" << EOF
    aes_x86_64
    ahci
    ast
    bridge
    hid
    hid_generic
    igb
    ixgbe
    usbhid
    video
    iptable_security
    iptable_raw
    iptable_mangle
    iptable_nat
    iptable_filter
EOF
else 
    cat > "${WORK_DIR}/etc/modules" << EOF
    aes_x86_64
    ahci
    ast
    bridge
    hid
    hid_generic
    igb
    ixgbe
    usbhid
    video
    iptable_security
    iptable_raw
    iptable_mangle
    iptable_nat
    iptable_filter
EOF
fi

cat > ${WORK_DIR}/etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
	"${distro_id}:${distro_codename}";
	"${distro_id}:${distro_codename}-security";
	"${distro_id}:${distro_codename}-updates";
	"${distro_id}:${distro_codename}-proposed";
	"${distro_id}:${distro_codename}-backports";
};
EOF

echo "phase 6"
# add padmin user
chroot "${WORK_DIR}" adduser --disabled-password --gecos "" ${SUDO_USER}
chroot "${WORK_DIR}" adduser ${SUDO_USER} sudo

# custom scripts
# build initramfs
echo "final phase: packaging"
cd "${WORK_DIR}" && find . | cpio -o -H newc | gzip -9 > /tmp/initramfs-live.gz
