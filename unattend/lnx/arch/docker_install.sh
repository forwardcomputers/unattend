#!/bin/sh
# 
echo 'Staring Arch Linux auto install'
#
sed -i 's/^\[DHCP]/\[DHCP]\nUseDomains=true/' /etc/systemd/network/ethernet.network
dhclient
curl -s -o/tmp/secrets http://filer/os/ks/arch/secrets
. /tmp/secrets
#
timedatectl set-ntp true
for x in $(cat /proc/cmdline); do
  case "$x" in
    dist_mirror=*)
      _mirror="${x#dist_mirror=}/\$repo/os/\$arch"
      ;;
  esac
done
if [ -z "${_mirror}" ]; then
  _mirror='https://mirror.csclub.uwaterloo.ca/archlinux/$repo/os/$arch'
fi

# Disk
_disk="/dev/${1:-nvme0n1}"
_swap_size=$(awk '/^MemTotal:/ {print int($2/1024/2)}' /proc/meminfo)

echo 'Initializing disks'
sgdisk -ZG "$_disk"
sgdisk -n 0:0:+261MiB -t 0:ef00 -c 0:boot \
-n 0:0:+"${_swap_size}"MiB -t 0:8200 -c 0:swap \
-n 0:0:0 -t 0:8300 -c 0:root "$_disk"

mkfs.fat -F32 "${_disk}p1"
mkswap "${_disk}p2"
mkfs.ext4 -F "${_disk}p3"

# Install system
echo "Server = $_mirror" > /etc/pacman.d/mirrorlist
mount "${_disk}p3" /mnt
mkdir -p /mnt/boot/efi
mount "${_disk}p1" /mnt/boot/efi

pacstrap /mnt \
 base \
 base-devel \
 bash-completion \
 bluez \
 bluez-utils \
 cronie \
 cockpit \
 cockpit-dashboard \
 cockpit-docker \
 cockpit-pcp \
 efibootmgr \
 git \
 grub \
 intel-ucode \
 inetutils \
 jq \
 linux \
 linux-firmware \
 msmtp-mta \
 networkmanager \
 nfs-utils \
 openssh \
 packagekit \
 pacman-contrib \
 sudo \
 udisks2 \
 vim
genfstab -pU /mnt >> /mnt/etc/fstab

# Arch tweaks in chroot system
arch-chroot /mnt <<-_EOF_
	#!/bin/sh

	echo
	echo 'Set timezone'
	# Setup system clock
	ln -s /usr/share/zoneinfo/America/Toronto /etc/localtime
	hwclock --systohc --utc

	echo 'Set locale'
	# Set the locale
	sed -i 's/^#en_US.UTF/en_US.UTF/' /etc/locale.gen
	locale-gen
	echo LANG=en_US.UTF-8 > /etc/locale.conf
	export LANG=en_US.UTF-8

	echo 'Set hostname'
	# Set the hostname
	echo ${_hostname} > /etc/hostname

	echo 'Set network'
	# Network
	cat > /etc/NetworkManager/system-connections/eth0.nmconnection <<-_EOF
		[connection]
		id=eth0
		interface-name=eth0
		type=ethernet

		[ipv4]
		address1=${_ip_address}
		dns=${_dns_address};
		dns-search=${_dns_name};
		gateway=${_gw_address}
		method=manual

		[ipv6]
		method=disabled

		[proxy]
	_EOF
	chmod 600 /etc/NetworkManager/system-connections/eth0.nmconnection

	echo 'Modify root'
	# Modifing root
	echo 'root:${_root_pw}' | chpasswd -e
	mkdir -p /root/.ssh
	curl -so /root/.ssh/authorized_keys https://github.com/forwardcomputers.keys
	chmod 700 /root/.ssh; chmod 600 /root/.ssh/authorized_keys
	cat > /root/.profile <<-_EOF
		alias pkgup="pacman -Syyu --noconfirm && pacman -Scc --noconfirm"
	_EOF
	curl -so /root/install.sh http://filer/os/docker-compose/portainer_install.sh
	# Add check for updates in crontab
	mkdir -p /var/spool/cron
	echo -e '0\t3\t*\t*\t*\techo -e "Subject: From DOCKER\n\n\nAvailable updates\n\n$(checkupdates)" | sendmail --host=filer -f docker alim@forwardcomputers.com' > /var/spool/cron/root
	chmod 600 /var/spool/cron/root

	echo 'Add user'
	# Adding user alternate user
	useradd -G docker -p '${_alt_pw}' ${_alt_user}
	mkdir -p /home/${_alt_user}/.ssh
	curl -so /home/${_alt_user}/.ssh/authorized_keys https://github.com/forwardcomputers.keys
	chown -R ${_alt_user}:${_alt_user} /home/${_alt_user}; chmod 700 /home/${_alt_user}/.ssh; chmod 600 /home/${_alt_user}/.ssh/authorized_keys
	echo '${_alt_user} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers.d/${_alt_user}

	echo 'Change issue file'
	# Change issue file
	cat > /etc/issue <<-_EOF
		\S on (\l)
		\U logged in user(s)

		IP address: \4

	_EOF

	echo 'Add color to prompt'
	# Add color to prompt
	cat >> /etc/bash.bashrc <<-_EOF
		alias ls='ls --color=auto'

		NORMAL="\[\e[0m\]"
		RED="\[\e[1;31m\]"
		GREEN="\[\e[1;32m\]"
		if [ "\\\$USER" = root ]; then
		  PS1="\\\$RED\u@\h [\\\$NORMAL\w\\\$RED]# \\\$NORMAL"
		else
		  PS1="\\\$GREEN\u@\h [\\\$NORMAL\w\\\$GREEN]\$ \\\$NORMAL"
		fi
	_EOF

	echo 'vim aliases'
	# vim aliases
	for _file in 'edit' 'ex' 'vedit' 'vi' 'view'; do
		ln -sf 'vim' "/usr/bin/\${_file}"
	done

	echo 'Add NFS mounts in fstab'
	# Add NFS mounts in fstab
	mkdir -p /opt/filer
	cat >> /etc/fstab <<-_EOF
	tmpfs /tmp  tmpfs defaults,noatime,mode=1777	0	0
	filer:/volume1/share /opt/filer nfs nfsvers=3,proto=tcp,rw,auto,hard,rsize=65536,wsize=65536,_netdev 0 0
	_EOF
	sed -i 's/relatime/noatime/g' /etc/fstab

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
	sed -i "s|-H fd://||" /usr/lib/systemd/system/docker.service

	echo 'Config cockpit'
	# Config cocpit
	cat > /etc/cockpit/cockpit.conf <<-_EOF
		[WebService]
		AllowUnencrypted = true
	_EOF

	echo 'Enable services'
	# Enable services
  mkdir -p /etc/systemd/system/getty@tty1.service.d
  cat > /etc/systemd/system/getty@tty1.service.d/noclear.conf <<-_EOF
		[Service]
		TTYVTDisallocate=no
	_EOF
	systemctl enable --now \
    bluetooth.service \
    cronie.service \
    cockpit.socket \
    docker.service \
    NetworkManager.service \
    sshd.service
	sed -i 's/^#AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf

	# Install grub
	sed -i 's/quiet/net.ifnames=0 ipv6.disable=1/' /etc/default/grub
	grub-install --target=x86_64-efi --recheck
	grub-mkconfig -o /boot/grub/grub.cfg

	# Exit chroot system
	exit
_EOF_

rm -f /mnt/root/.bash_history
umount -R /mnt
echo $'\n\nInstallation finished\n\n'
reboot
