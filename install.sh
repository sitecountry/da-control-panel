#!/bin/sh

###############################################################################
# setup.sh
# DirectAdmin  setup.sh  file  is  the  first  file  to  download  when doing a
# DirectAdmin Install.  If  you  are unable to run this script with
# ./setup.sh  then  you probably need to set it's permissions.  You can do this
# by typing the following:
#
# chmod 755 setup.sh
#
# after this has been done, you can type ./setup.sh to run the script.
#
###############################################################################

color_reset=$(tput -Txterm sgr0)
green=$(tput -Txterm setaf 2)
red=$(tput -Txterm setaf 1)

echogreen () {
	echo "[setup.sh] ${green}$*${color_reset}"
}

echored () {
	echo "[setup.sh] ${red}$*${color_reset}"
}


if [ "$(id -u)" != "0" ]; then
	echored "You must be root to execute the script. Exiting."
	exit 1
fi

if ! uname -m | grep -m1 -q 64; then
	echored "This is a 32-bit machine, we support only 64-bit installations. Exiting."
	exit 1
fi

#Global variables
DA_CHANNEL=${DA_CHANNEL:="current"}
DA_OS_SLUG=${DA_OS_SLUG:="linux_amd64"}
DA_PATH=/usr/local/directadmin
DACONF=${DA_PATH}/conf/directadmin.conf
LICENSE=${DA_PATH}/conf/license.key
DA_TQ="${DA_PATH}/data/task.queue"
DA_SCRIPTS="${DA_PATH}/scripts"

SETUP_TXT="${DA_SCRIPTS}/setup.txt"

DL_SERVER=files.directadmin.com
BACKUP_DL_SERVER=files-de.directadmin.com

SYSTEMD=false
SYSTEMDDIR=/etc/systemd/system
if [ -d ${SYSTEMDDIR} ]; then
	if [ -e /bin/systemctl ] || [ -e /usr/bin/systemctl ]; then
		SYSTEMD=true
	fi
fi

case "${1}" in
	--help|help|\?|-\?|h)
		echo ""
		echo "Usage: $0 <license_key>"
		echo ""
		echo "or"
		echo ""
		echo "Usage: DA_CHANNEL=\"beta\" $0 <license_key>"
		echo ""
		echo "You may use the following environment variables to pre-define the settings:"
		echo "  DA_CHANNEL : Download channel: alpha, beta, current, stable"
		echo "   DA_COMMIT : Exact DA build to install, will use latest from update channel if empty"
		echo "  DA_OS_SLUG : Build targeting specific platform: linux_amd64, debian10_amd64, rhel8_amd64, ..."
		echo "    DA_EMAIL : Default email address"
		echo " DA_HOSTNAME : Hostname to use for installation"
		echo "  DA_ETH_DEV : Network device"
		echo "      DA_NS1 : pre-defined ns1"
		echo "      DA_NS2 : pre-defined ns2"
		echo ""
		echo "Just set any of these environment variables to non-empty value (for example, DA_SKIP_CSF=true) to:"
		echo "            DA_SKIP_FASTEST : do not check for fastest server"
		echo "                DA_SKIP_CSF : skip installation of CFS firewall"
		echo "      DA_SKIP_MYSQL_INSTALL : skip installation of MySQL/MariaDB"
		echo "         DA_SKIP_SECURE_PHP : skip disabling insecure PHP functions automatically"
		echo "        DA_SKIP_CUSTOMBUILD : skip all the CustomBuild actions"
		echo " DA_INTERACTIVE_CUSTOMBUILD : run interactive CustomBuild installation if DA_SKIP_CUSTOMBUILD is unset"
		echo " DA_FOREGROUND_CUSTOMBUILD  : run CustomBuild installation in foreground DA_SKIP_CUSTOMBUILD is unset"
		echo ""
		echo "To customize any CustomBuild options, we suggest using environment variables: https://docs.directadmin.com/getting-started/installation/overview.html#running-the-installation-with-predefined-options"
		echo ""
		exit 0
		;;
esac

if [ -e /etc/debian_version ]; then
        apt-get --quiet --yes update
fi

if ! command -v dig > /dev/null || ! command -v curl > /dev/null || ! command -v tar > /dev/null || ! command -v perl > /dev/null; then
	echogreen "Installing dependencies..."
	if [ -e /etc/debian_version ]; then
		apt-get --quiet --quiet --yes install curl tar perl bind9-dnsutils || apt-get --quiet --quiet --yes install curl tar perl dnsutils
	else
		yum --quiet --assumeyes install curl tar perl bind-utils
	fi
fi

if ! command -v curl > /dev/null; then
	echored "Please make sure 'curl' tool is available on your system and try again."
	exit 1
fi
if ! command -v tar > /dev/null; then
	echored "Please make sure 'tar' tool is available on your system and try again."
	exit 1
fi
if ! command -v perl > /dev/null; then
	echored "Please make sure 'perl' tool is available on your system and try again."
	exit 1
fi

#HOSTNAME CHECKS#
if [ -n "${DA_HOSTNAME}" ]; then
	HOST="${DA_HOSTNAME}"
elif [ -e "/root/.use_hostname" ]; then
	HOST="$(head -n 1 < /root/.use_hostname)"
fi
if [ -z "${HOST}" ]; then
	if [ -x /usr/bin/hostnamectl ]; then
		HOST="$(/usr/bin/hostnamectl --static | head -n1)"
		if [ -z "${HOST}" ]; then
			HOST="$(/usr/bin/hostnamectl --transient | head -n1)"
		fi
		if [ -z "${HOST}" ]; then
			HOST="$(hostname -f 2>/dev/null)"
		fi
		if ! echo "${HOST}" | grep  -m1 -q '\.'; then
			HOST="$(grep -m1 -o "${HOST}\.[^[:space:]]*" /etc/hosts)"
		fi
	else
		HOST="$(hostname -f)"
	fi
fi

if [ "${HOST}" = "localhost" ]; then
	echo "'localhost' is not valid for the hostname. Setting it to server.hostname.com, you can change it later in Admin Settings"
	HOST=server.hostname.com
fi
if ! echo ${HOST} | grep -o '\.' | grep -m1 '\.'; then
	echo "'${HOST}' is not valid for the hostname. Setting it to server.hostname.com, you can change it later in Admin Settings"
	HOST=server.hostname.com
fi

random_pass() {
	PASS_LEN=$(perl -le 'print int(rand(6))+9')
	START_LEN=$(perl -le 'print int(rand(8))+1')
	END_LEN=$((PASS_LEN - START_LEN))
	SPECIAL_CHAR=$(perl -le 'print map { (qw{@ ^ _ - /})[rand 6] } 1')
	NUMERIC_CHAR=$(perl -le 'print int(rand(10))')
	PASS_START=$(perl -le "print map+(A..Z,a..z,0..9)[rand 62],0..$START_LEN")
	PASS_END=$(perl -le "print map+(A..Z,a..z,0..9)[rand 62],0..$END_LEN")
	PASS=${PASS_START}${SPECIAL_CHAR}${NUMERIC_CHAR}${PASS_END}
	echo "$PASS"
}

ADMIN_USER="admin"
ADMIN_PASS=$(random_pass)

# Get the other info
EMAIL=${ADMIN_USER}@${HOST}
if [ -s /root/.email.txt ] && [ -z "${DA_EMAIL}" ]; then
	EMAIL=$(head -n 1 < /root/.email.txt)
elif [ -n "${DA_EMAIL}" ]; then
	EMAIL="${DA_EMAIL}"
fi

TEST=$(echo "$HOST" | cut -d. -f3)
if [ "$TEST" = "" ]; then
	NS1=ns1.$(echo "$HOST" | cut -d. -f1,2)
	NS2=ns2.$(echo "$HOST" | cut -d. -f1,2)
else
	NS1=ns1.$(echo "$HOST" | cut -d. -f2,3,4,5,6)
	NS2=ns2.$(echo "$HOST" | cut -d. -f2,3,4,5,6)
fi

if [ -s /root/.ns1.txt ] && [ -s /root/.ns2.txt ] && [ -z "${DA_NS1}" ] && [ -z "${DA_NS2}" ]; then
	NS1=$(head -n1 < /root/.ns1.txt)
	NS2=$(head -n1 < /root/.ns2.txt)
elif [ -n "${DA_NS1}" ] && [ -n "${DA_NS2}" ]; then
	NS1="${DA_NS1}"
	NS2="${DA_NS2}"
fi

if [ $# -eq 0 ]; then
	LK=""
	until [ "${#LK}" -eq 44 ]; do
		printf "Please enter your License Key: "
		read -r LK
	done
	DA_INTERACTIVE_CUSTOMBUILD=true
elif [ "$1" = "auto" ] || [ $# -ge 4 ]; then
	if [ -e /root/.skip_get_license ]; then
		LK="skipped"
	else
		LK=$(curl --silent --location https://www.directadmin.com/clients/my_license_info.php | grep -m1 '^license_key=' | cut -d= -f2,3)
	fi
	if [ -z "${LK}" ]; then
		for ip_address in $(ip -o addr | awk '!/^[0-9]*: ?lo|link\/ether/ {print $4}' | cut -d/ -f1 | grep -v ^fe80); do {
			LK=$(curl --silent --connect-timeout 20 --interface "${ip_address}" --location https://www.directadmin.com/clients/my_license_info.php | grep -m1 '^license_key=' | cut -d= -f2,3)
			if [ -n "${LK}" ]; then
				break
			fi
		};
		done
	fi
	case "$2" in
		alpha|beta|current|stable)
			DA_CHANNEL="$2"
	esac
	if [ -z "${LK}" ]; then
		echo "Unable to detect your license key, please re-run setup.sh with LK provided as the argument."
		exit 1
	fi
	if [ $# -ge 4 ]; then
		DA_HOSTNAME=$3
	fi
else
	LK="$1"
fi

###############################################################################
set -e

if [ -z "${DA_COMMIT}" ]; then
	echogreen "Checking for latest build in '${DA_CHANNEL}' release channel..."
	DA_COMMIT=$( (dig +short -t txt "${DA_CHANNEL}-version.directadmin.com" 2>/dev/null || curl --silent "https://dns.google/resolve?name=${DA_CHANNEL}-version.directadmin.com&type=txt" || curl --silent --header 'Accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=${DA_CHANNEL}-version.directadmin.com&type=txt") | sed 's|.*commit=\([0-9a-f]*\).*|\1|')
fi

if [ -z "${DA_COMMIT}" ]; then
	echored "Unable to detect download URL. Please make there are no problems with internet connectivity, IPv6 may be configured improperly."
	exit 1
fi


echo ""
echogreen "Welcome to DirectAdmin installer!"
echo ""
echogreen "Using these parameters for the installation:"
echo "                License Key: ${LK}"
echo "                 DA_CHANNEL: ${DA_CHANNEL}"
echo "                  DA_COMMIT: ${DA_COMMIT}"
echo "                 DA_OS_SLUG: ${DA_OS_SLUG}"
echo "                   DA_EMAIL: ${EMAIL}"
echo "                DA_HOSTNAME: ${HOST}"
echo "                     DA_NS1: ${NS1}"
echo "                     DA_NS2: ${NS2}"
echo "            DA_SKIP_FASTEST: ${DA_SKIP_FASTEST:-no}"
echo "                DA_SKIP_CSF: ${DA_SKIP_CSF:-no}"
echo "      DA_SKIP_MYSQL_INSTALL: ${DA_SKIP_MYSQL_INSTALL:-no}"
echo "         DA_SKIP_SECURE_PHP: ${DA_SKIP_SECURE_PHP:-no}"
echo "        DA_SKIP_CUSTOMBUILD: ${DA_SKIP_CUSTOMBUILD:-no}"
echo " DA_INTERACTIVE_CUSTOMBUILD: ${DA_INTERACTIVE_CUSTOMBUILD:-no}"
echo "  DA_FOREGROUND_CUSTOMBUILD: ${DA_FOREGROUND_CUSTOMBUILD:-no}"
echo ""

FILE="directadmin_${DA_COMMIT}_${DA_OS_SLUG}.tar.gz"
TMP_DIR=$(mktemp -d)
cleanup() {
        rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echogreen "Downloading DirectAdmin distribution package ${FILE}..."
curl --progress-bar --location --connect-timeout 60 -o "${TMP_DIR}/${FILE}" "https://download.directadmin.com/${FILE}" \
	|| curl --progress-bar --location --connect-timeout 60 -o "${TMP_DIR}/${FILE}" "https://download-alt.directadmin.com/${FILE}"
echogreen "Extracting DirectAdmin package ${FILE} to /usr/local/directadmin ..."
mkdir -p "${DA_PATH}"
tar xzf "${TMP_DIR}/${FILE}" -C "${DA_PATH}"

echogreen "Starting installation..."

if [ -e ${DACONF} ]; then
	echo ""
	echo ""
	echo "*** DirectAdmin already exists ***"
	echo "    Press Ctrl-C within the next 10 seconds to cancel the install"
	echo "    Else, wait, and the install will continue, but will destroy existing data"
	echo ""
	echo ""
	sleep 10
fi

if [ -e /usr/local/cpanel ]; then
        echo ""
        echo ""
        echo "*** CPanel exists on this system ***"
        echo "    Press Ctrl-C within the next 10 seconds to cancel the install"
        echo "    Else, wait, and the install will continue overtop (as best it can)"
        echo ""
        echo ""
        sleep 10
fi

if [ -e "/etc/debian_version" ]; then
	OS_VER=$(head -n1 < /etc/debian_version)

	if [ "$OS_VER" = "stretch/sid" ]; then
		OS_VER=9.0
	fi

	if [ "$OS_VER" = "buster/sid" ]; then
		echo "This appears to be Debian version $OS_VER which is Debian 10";
		OS_VER=10.0
	fi

	if [ "$OS_VER" = "bullseye/sid" ]; then
		echo "This appears to be Debian version $OS_VER which is Debian 11";
		OS_VER=11.0
	fi

else
	OS_VER=$(grep -m1 -o '[0-9]*\.[0-9]*[^ ]*' /etc/redhat-release | head -n1 | cut -d'.' -f1,2)
	if [ -z "${OS_VER}" ]; then
		OS_VER=$(grep -m1 -o '[0-9]*$' /etc/redhat-release)
	fi
fi

OS_MAJ_VER=$(echo "$OS_VER" | cut -d. -f1)

echo "* Installing pre-install packages ....";
if [ -e "/etc/debian_version" ]; then
	if [ "${OS_MAJ_VER}" -ge 10 ]; then
		apt-get -y install gcc g++ make flex bison openssl libssl-dev perl perl-base perl-modules libperl-dev libperl4-corelibs-perl libaio1 libaio-dev \
			zlib1g zlib1g-dev libcap-dev cron bzip2 zip automake autoconf libtool cmake pkg-config python3 libdb-dev libsasl2-dev \
			libncurses5 libncurses5-dev libsystemd-dev dnsutils quota patch logrotate rsyslog libc6-dev libexpat1-dev \
			libcrypt-openssl-rsa-perl libnuma-dev libnuma1 ipset libcurl4-openssl-dev curl psmisc libkrb5-dev ca-certificates
	else
		apt-get -y install gcc g++ make flex bison openssl libssl-dev perl perl-base perl-modules libperl-dev libperl4-corelibs-perl libaio1 libaio-dev zlib1g zlib1g-dev libcap-dev cron bzip2 zip automake autoconf libtool cmake pkg-config python libdb-dev libsasl2-dev libncurses5-dev libsystemd-dev dnsutils quota patch libjemalloc-dev logrotate rsyslog libc6-dev libexpat1-dev libcrypt-openssl-rsa-perl libnuma-dev libnuma1 ipset libcurl4-openssl-dev curl psmisc libkrb5-dev ca-certificates
	fi
else
	if [ "${OS_MAJ_VER}" -ge 9 ]; then
		yum -y install iptables tar gcc gcc-c++ flex bison make openssl openssl-devel perl quota libaio \
			libcom_err-devel libcurl-devel gd zlib-devel zip unzip libcap-devel cronie bzip2 cyrus-sasl-devel perl-ExtUtils-Embed \
			autoconf automake libtool which patch s-nail bzip2-devel lsof glibc-headers kernel-devel expat-devel \
			psmisc net-tools systemd-devel libdb-devel perl-DBI xfsprogs rsyslog logrotate crontabs file \
			kernel-headers hostname ipset krb5-devel e2fsprogs
	elif [ "${OS_MAJ_VER}" -ge 8 ]; then
		yum -y install iptables tar gcc gcc-c++ flex bison make openssl openssl-devel perl quota libaio \
			libcom_err-devel libcurl-devel gd zlib-devel zip unzip libcap-devel cronie bzip2 cyrus-sasl-devel perl-ExtUtils-Embed \
			autoconf automake libtool which patch mailx bzip2-devel lsof glibc-headers kernel-devel expat-devel \
			psmisc net-tools systemd-devel libdb-devel perl-DBI xfsprogs rsyslog logrotate crontabs file \
			kernel-headers hostname ipset krb5-devel e2fsprogs
	elif [ "${OS_MAJ_VER}" -ge 7 ]; then
		yum -y install iptables tar gcc gcc-c++ flex bison make openssl openssl-devel perl quota libaio \
			libcom_err-devel libcurl-devel gd zlib-devel zip unzip libcap-devel cronie bzip2 cyrus-sasl-devel perl-ExtUtils-Embed \
			autoconf automake libtool which patch mailx bzip2-devel lsof glibc-headers kernel-devel expat-devel \
			psmisc net-tools systemd-devel libdb-devel perl-DBI perl-Perl4-CoreLibs xfsprogs rsyslog logrotate crontabs file kernel-headers ipset krb5-devel e2fsprogs
	else
		yum -y install tar gcc gcc-c++ flex bison make openssl openssl-devel perl quota libaio \
			libcom_err-devel libcurl-devel gd zlib-devel zip unzip libcap-devel cronie bzip2 cyrus-sasl-devel perl-ExtUtils-Embed \
			autoconf automake libtool which patch mailx bzip2-devel lsof glibc-headers kernel-devel expat-devel db4-devel ipset krb5-devel e2fsprogs
	fi
fi
echo "*";
echo "*****************************************************";
echo "";

###############################################################################
###############################################################################

# We now have all information gathered, now we need to start making decisions

if [ -e "/etc/debian_version" ] && [ -e /bin/bash ] && [ -e /bin/dash ]; then
	if ls -la /bin/sh | grep -q dash; then
		ln -sf /bin/bash /bin/sh
	fi
fi

#######
# Ok, we're ready to go.
if [ -e "/etc/debian_version" ] && [ -e /etc/apparmor.d ]; then
	mkdir -p /etc/apparmor.d/disable
	for aa_file in /etc/apparmor.d/*; do
		if [ -f "$aa_file" ]; then
			ln -s "$aa_file" /etc/apparmor.d/disable/ 2>/dev/null || true
			if [ -x /sbin/apparmor_parser ]; then
				/sbin/apparmor_parser -R "$aa_file" 2>/dev/null || true
			fi
		fi
	done
fi

if [ -s /usr/sbin/ntpdate ]; then
	/usr/sbin/ntpdate -b -u pool.ntp.org
fi

if [ -n "${DA_SKIP_MYSQL_INSTALL}" ]; then
	export mysql_inst=no
fi

#ensure /etc/hosts has localhost
if ! grep 127.0.0.1 /etc/hosts | grep -q localhost; then
	printf "127.0.0.1\t\tlocalhost" >> /etc/hosts
fi

OLDHOST=$(hostname --fqdn)
if [ "${OLDHOST}" = "" ]; then
	echo "old hostname is blank. Setting a temporary placeholder"
	/bin/hostname $HOST
	sleep 5
fi

###############################################################################

# write the setup.txt

NM=$(ip -o -f inet addr show scope global | grep -o 'inet [^ ]*' | grep -m1 -o '/[0-9]*' 2>/dev/null)
EXTERNAL_IP=$(curl --silent --location http://myip.directadmin.com 2>/dev/null | head -n1)
{
	echo "hostname=$HOST"
	echo "email=$EMAIL"
	echo "adminname=$ADMIN_USER"
	echo "adminpass=$ADMIN_PASS"
	echo "ns1=$NS1"
	echo "ns2=$NS2"
	echo "netmask=$NM"
	echo "ip=$EXTERNAL_IP"
} > ${SETUP_TXT}

chmod 600 ${SETUP_TXT}

###############################################################################
###############################################################################

#Create the diradmin user
createDAbase() {
	if ! id diradmin; then
		if [ -e /etc/debian_version ]; then
			/usr/sbin/adduser --system --group --firstuid 100 --home ${DA_PATH} --no-create-home --disabled-login --force-badname diradmin
		else
			/usr/sbin/useradd -d ${DA_PATH} -r -s /bin/false diradmin 2> /dev/null
		fi
	fi

	if [ -e /etc/logrotate.d ]; then
		cp $DA_SCRIPTS/directadmin.rotate /etc/logrotate.d/directadmin
		chmod 644 /etc/logrotate.d/directadmin
	fi

	mkdir -p /var/log/httpd/domains
	chmod 710 /var/log/httpd/domains
	chmod 710 /var/log/httpd

	ULTMP_HC=/usr/lib/tmpfiles.d/home.conf
	if [ -s ${ULTMP_HC} ]; then
		#Q /home 0755 - - -
		if grep -m1 -q '^Q /home 0755 ' ${ULTMP_HC}; then
			perl -pi -e 's#^Q /home 0755 #Q /home 0711 #' ${ULTMP_HC};
		fi
	fi

	mkdir -p /var/www/html
	chmod 755 /var/www/html
}

#After everything else copy the directadmin_cron to /etc/cron.d
copyCronFile() {
	mkdir -p /etc/cron.d
	cp -f ${DA_SCRIPTS}/directadmin_cron /etc/cron.d/;
	chmod 600 /etc/cron.d/directadmin_cron
	chown root /etc/cron.d/directadmin_cron
		
	#CentOS/RHEL bits
	if [ ! -s /etc/debian_version ]; then
		CRON_BOOT=/etc/init.d/crond
		if ${SYSTEMD}; then
			CRON_BOOT=/usr/lib/systemd/system/crond.service
		fi

		if [ ! -s ${CRON_BOOT} ]; then
			echo ""
			echo "****************************************************************************"
			echo "* Cannot find ${CRON_BOOT}.  Ensure you have cronie installed"
			echo "    yum install cronie"
			echo "****************************************************************************"
			echo ""
		else
			if ${SYSTEMD}; then
				systemctl daemon-reload
				systemctl enable crond.service
				systemctl restart crond.service
			else
				${CRON_BOOT} restart
				/sbin/chkconfig crond on
			fi
		fi
	fi
}

#Copies the startup scripts over to the /etc/rc.d/init.d/ folder 
#and chkconfig's them to enable them on bootup
copyStartupScripts() {
	if ${SYSTEMD}; then
		cp -f ${DA_SCRIPTS}/directadmin.service ${SYSTEMDDIR}/
		cp -f ${DA_SCRIPTS}/startips.service ${SYSTEMDDIR}/
		chmod 644 ${SYSTEMDDIR}/startips.service

		systemctl daemon-reload

		systemctl enable directadmin.service
		systemctl enable startips.service
	else
		cp -f ${DA_SCRIPTS}/directadmin /etc/init.d/directadmin
		cp -f ${DA_SCRIPTS}/startips /etc/init.d/startips
		# nothing for debian as non-systemd debian versions are EOL
		if [ ! -s /etc/debian_version ]; then
			/sbin/chkconfig directadmin reset
			/sbin/chkconfig startips reset
		fi
	fi
}

getLicense() {
	if [ -e /root/.skip_get_license ]; then
		echo "/root/.skip_get_license exists. Not downloading license"
		return
	fi

	mkdir -p "${DA_PATH}/conf"
	echo "$1" > "${DA_PATH}/conf/license.key"
	chmod 600 "${DA_PATH}/conf/license.key"
}

doSetHostname() {
	HN=$(grep hostname= ${SETUP_TXT} | cut -d= -f2)
	${DA_SCRIPTS}/hostname.sh "${HN}"
}

${DA_SCRIPTS}/doChecks.sh

doSetHostname
createDAbase
copyStartupScripts
${DA_SCRIPTS}/fstab.sh
${DA_SCRIPTS}/cron_deny.sh

getLicense "$LK"

cp -f ${DA_SCRIPTS}/redirect.php /var/www/html/redirect.php

if grep -m1 -q '^adminname=' ${SETUP_TXT}; then
	ADMINNAME=$(grep -m1 '^adminname=' ${SETUP_TXT} | cut -d= -f2)
	if getent passwd ${ADMINNAME} > /dev/null 2>&1; then
		userdel -r "${ADMINNAME}" 2>/dev/null
	fi
	rm -rf "${DA_PATH}/data/users/${ADMINNAME}"
fi

#set ethernet device
if [ -n "${DA_ETH_DEV}" ] ; then
	ETH_DEV="${DA_ETH_DEV}"
elif [ -s ${DACONF} ]; then
	ETH_DEV=$(grep -E '^ethernet_dev=' ${DACONF} | cut -d= -f2)
fi

#moved here march 7, 2011
copyCronFile

${DA_PATH}/directadmin install  	 \
	"--adminname=${ADMIN_USER}" 	 \
	"--adminpass=${ADMIN_PASS}" 	 \
	"--update-channel=${DA_CHANNEL}" \
	"--email=${EMAIL}"          	 \
	"--hostname=${HOST}"        	 \
	"--network-dev=${ETH_DEV}"  	 \
	"--ip=${EXTERNAL_IP}"       	 \
	"--netmask=${NM}"           	 \
	"--ns1=${NS1}"              	 \
	"--ns2=${NS2}"              	 \
	|| exit 1

echo ""
echo "System Security Tips:"
echo "  https://docs.directadmin.com/operation-system-level/securing/general.html#basic-system-security"
echo ""

if [ ! -s $DACONF ]; then
	echo "";
	echo "*********************************";
	echo "*";
	echo "* Cannot find $DACONF";
	echo "* Please see this guide:";
	echo "* https://docs.directadmin.com/directadmin/general-usage/troubleshooting-da-service.html#directadmin-not-starting-cannot-execute-binary-file";
	echo "*";
	echo "*********************************";
	exit 1;
fi

if ${SYSTEMD}; then
	if ! systemctl restart directadmin.service; then
		echored "Failed to start directadmin service, please make sure you have a valid license"
		systemctl --no-pager status directadmin.service
		exit 1
	fi
elif [ -e /etc/rc.d/init.d/directadmin ]; then
	/etc/rc.d/init.d/directadmin restart
fi

if [ -e /usr/local/directadmin/da-internal.sock ]; then
	${DA_PATH}/dataskq --custombuild
fi

#link things up for the lan.
#get the server IP
IP=$(curl --location --silent --connect-timeout 6 http://myip.directadmin.com 2>/dev/null)
LAN_IP=$(${DA_PATH}/scripts/get_main_ip.sh)

if [ "${IP}" != "" ] && [ "${LAN_IP}" != "" ]; then
	if [ "${IP}" != "${LAN_IP}" ]; then
		#Let us confirm that the LAN IP actually gives us the correct server IP.
		echo "Confirming that 'curl --location --silent --connect-timeout 6 --interface ${LAN_IP} http://myip.directadmin.com' returns ${IP} ..."
		EXTERNAL_IP=$(curl --location --silent --connect-timeout 6 --interface "${LAN_IP}" --disable --output - http://myip.directadmin.com 2>&1 || echo "")
		if [ -n "${EXTERNAL_IP}" ]; then
			#we got the IP WITH the bind
			if [ "${EXTERNAL_IP}" = "${IP}" ]; then
				echo "LAN IP SETUP: Binding to ${LAN_IP} did return the correct IP address.  Completing last steps of Auto-LAN setup ..."
				echo "Adding lan_ip=${LAN_IP} to directadmin.conf ..."
				${DA_PATH}/directadmin set lan_ip "${LAN_IP}"
				echo 'action=directadmin&value=restart' >> ${DA_TQ}

				echo "Linking ${LAN_IP} to ${IP}"
				NETMASK=$(grep -m1 ^netmask= ${SETUP_TXT} | cut -d= -f2)
				echo "action=linked_ips&ip_action=add&ip=${IP}&ip_to_link=${LAN_IP}&apache=yes&dns=no&apply=yes&add_to_ips_list=yes&netmask=${NETMASK}" >> ${DA_TQ}.cb
				${DA_PATH}/dataskq --custombuild
				
				echo "LAN IP SETUP: Done."
			else
				echo "*** scripts/install.sh: LAN: when binding to ${LAN_IP}, curl returned external IP ${EXTERNAL_IP}, which is odd."
				echo "Not automatically setting up the directadmin.conf:lan_ip=${LAN_IP}, and not automatically linking ${LAN_IP} to ${IP}"
				sleep 2
			fi
		fi
	fi
fi

if [ -e /etc/aliases ]; then
	if ! grep -q diradmin /etc/aliases; then
		echo "diradmin: :blackhole:" >> /etc/aliases
	fi
fi

if [ -s ${DACONF} ]; then
	echo ""
	echo "DirectAdmin should be accessible now";
	echo "If you cannot connect to the login URL, then it is likely that a firewall is blocking port 2222. Please see:"
	echo "  https://docs.directadmin.com/directadmin/general-usage/troubleshooting-da-service.html#cannot-connect-to-da-on-port-2222"
fi

if [ -z "${DA_SKIP_CUSTOMBUILD}" ]; then
	# Install CustomBuild
	if ! curl --location --progress-bar --output "${TMP_DIR}/custombuild.tar.gz" http://${DL_SERVER}/services/custombuild/2.0/custombuild.tar.gz || ! curl --location --progress-bar --output "${TMP_DIR}/custombuild.tar.gz" http://${BACKUP_DL_SERVER}/services/custombuild/2.0/custombuild.tar.gz; then
		echo "*** There was an error downloading the custombuild script. ***"
		exit 1
	fi
	tar xzf "${TMP_DIR}/custombuild.tar.gz" -C ${DA_PATH}
	chmod 755 "${DA_PATH}/custombuild/build"
	echo "CustomBuild installation has started, you may check the progress using the following command: tail -f ${DA_PATH}/custombuild/install.txt"
	if [ -n "${DA_INTERACTIVE_CUSTOMBUILD}" ] && [ ! -s /usr/local/directadmin/custombuild/options.conf ]; then
		${DA_PATH}/custombuild/build create_options
	elif [ -z "${DA_SKIP_SECURE_PHP}" ]; then
		/usr/local/directadmin/custombuild/build set secure_php yes > ${DA_PATH}/custombuild/install.txt 2>&1
	fi
	if [ ! -e /root/.skip_csf ] && [ -z "${DA_SKIP_CSF}" ]; then
		/usr/local/directadmin/custombuild/build set csf yes >> ${DA_PATH}/custombuild/install.txt 2>&1
	fi
	if [ ! -e /root/.using_fastest ] && [ ! -n "${DA_SKIP_FASTEST}" ]; then
		${DA_PATH}/custombuild/build set_fastest >> ${DA_PATH}/custombuild/install.txt 2>&1
	fi

	${DA_PATH}/custombuild/build update >> ${DA_PATH}/custombuild/install.txt 2>&1 &
	if [ -z "${DA_FOREGROUND_CUSTOMBUILD}" ]; then
		${DA_PATH}/custombuild/build all d >> ${DA_PATH}/custombuild/install.txt 2>&1 &
		echogreen "You will receive a message in the DirectAdmin panel when background installation finalizes."
	else
		${DA_PATH}/custombuild/build all d | tee ${DA_PATH}/custombuild/install.txt
	fi
fi

echo ""
echo "The following information has been set:"
echo "Admin username: ${ADMIN_USER}"
echo "Admin password: ${ADMIN_PASS}"
echo "Admin email: ${EMAIL}"
echo ""
echo ""
echo "Server IP: ${EXTERNAL_IP}"
echo "Server Hostname: ${HOST}"
echo ""
echogreen "To login now, follow this URL: $(/usr/local/directadmin/directadmin --create-login-url user=${ADMIN_USER})"

printf \\a
sleep 1
printf \\a
sleep 1
printf \\a

exit 0
