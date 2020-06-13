#!/bin/sh
# 
echo 'Staring Alpine Linux auto install'
#
wget -q -O /tmp/secrets http://filer/os/ks/alpine/secrets
. /tmp/secrets

# Install system
cat > /tmp/alpine-setup-vars <<-_EOF
	KEYMAPOPTS="us us"
	HOSTNAMEOPTS="-n docker"
	INTERFACESOPTS="auto lo
	iface lo inet loopback

	auto eth0
	iface eth0 inet static
		address ${_ip_address}
		netmask ${_netmask}
		gateway ${_gw_address}
		hostname ${_hostname}
	"
	DNSOPTS="-d ${_dns_name} ${_dns_address}"
	TIMEZONEOPTS="-z America/Toronto"
	PROXYOPTS="none"
	APKREPOSOPTS="https://mirror.csclub.uwaterloo.ca/alpine/edge/main
	https://mirror.csclub.uwaterloo.ca/alpine/edge/community
	https://mirror.csclub.uwaterloo.ca/alpine/edge/testing"
	APKCACHEOPTS="/var/cache/apk"
	SSHDOPTS="-c openssh"
	NTPOPTS="-c openntpd"
	DISKOPTS="-m sys /dev/nvme0n1"
	DISKLABEL="gpt"
	USE_EFI=
	BOOTLOADER="grub"
	BOOTFS="vfat"
	BOOTSIZE="260"
	ROOTFS="ext4"
	ERASE_DISKS="/dev/nvme0n1"
	MKFS_OPTS_ROOT="-F"
_EOF

sed -i 's/^DEFAULT_DISK=none/DEFAULT_DISK=none ERASE_DISKS=$ERASE_DISKS MKFS_OPTS_ROOT=$MKFS_OPTS_ROOT/' /sbin/setup-alpine
setup-alpine -e -f /tmp/alpine-setup-vars
mount /dev/nvme0n1p3 /mnt

# Add-ons and tweaks
chroot /mnt <<-_EOF_
	#!/bin/sh

	echo 'Update & install packages'
	# Update & install packages
	apk --update add bluez curl eudev docker iproute2 jq nfs-utils sudo

	echo 'Modify root'
	# Modifing root
	echo 'root:${_root_pw}' | chpasswd -e
	mkdir -p /root/.ssh
	wget -q -O /root/.ssh/authorized_keys https://github.com/forwardcomputers.keys
	chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys
	cat > /root/.profile <<-_EOF
		alias pkgup="apk update -U --purge && apk upgrade -U --available --purge"
	_EOF
	wget -P /root http://filer/os/docker-compose/portainer_install.sh
	# Add check for updates in crontab
	echo -e '0\t3\t*\t*\t*\tprintf "%s\\\n" "Subject: From DOCKER" "" "" "\$(echo UPDATE && apk update -U --purge && echo && echo UPGRADE && apk upgrade -U --available --purge -s)" | sendmail -f docker -S filer alim@forwardcomputers.com' >> /etc/crontabs/root
	chmod 600 /etc/crontabs/root

	echo 'Add user'
	# Adding user alternate user
	adduser -D ${_alt_user}
	echo '${_alt_user}:${_alt_pw}' | chpasswd -e
	addgroup ${_alt_user} docker
	mkdir -p /home/${_alt_user}/.ssh
	wget -q -O /home/${_alt_user}/.ssh/authorized_keys https://github.com/forwardcomputers.keys
	chown -R ${_alt_user}:${_alt_user} /home/${_alt_user}; chmod 700 /home/${_alt_user}/.ssh; chmod 600 /home/${_alt_user}/.ssh/authorized_keys
	echo '${_alt_user} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/${_alt_user}

	echo 'Add color to prompt'
	# Add color to prompt
	mv /etc/profile.d/color_prompt /etc/profile.d/color_prompt.sh
	sed -i 's/\\h /\\u@\\\h /' /etc/profile.d/color_prompt.sh

	echo 'Add NFS mounts in fstab'
	# Add NFS mounts in fstab
	mkdir -p /opt/filer
	cat >> /etc/fstab <<-_EOF
		tmpfs		/tmp	tmpfs	nodev,nosuid,size=8G	0 0
		${_ip_filer}:/volume1/share	/opt/filer	nfs	nfsvers=3,proto=tcp,rw,auto,hard,nolock,rsize=65536,wsize=65536,_netdev	0 0
	_EOF

	echo 'Change docker'
	# Change docker
	mkdir -p /etc/docker
	cat > /etc/docker/daemon.json <<-_EOF
	{
	  "experimental": true,
	  "hosts": ["unix://", "tcp://0.0.0.0:2375"],
	  "log-opts": {
	    "max-size": "10m",
	    "max-file":"5"
	  },
	  "metrics-addr": "0.0.0.0:9323"
	}
	_EOF

	echo 'Network configurations'
	# Network configurations
	cat >> /etc/network/interfaces <<-_EOF
		dns-nameservers ${_dns_address}
		dns-search ${_dns_name}
	_EOF
	sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

	# Finalize
	echo 'rc_need="nfsmount"' >> /etc/conf.d/docker
	rc-update add dbus
	rc-update add bluetooth
	rc-update add docker default
	rc-update add nfsmount default
	setup-udev 2>/dev/null
	echo > /etc/motd
_EOF_

umount /mnt
echo $'\n\nInstallation finished\n\n'
reboot
