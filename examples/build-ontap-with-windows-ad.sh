#!/bin/bash

export LANG=C
run() {
	[[ $# -eq 0 ]] && return 0

	echo "[run]" "$@"
	"$@"
}
getDefaultIp4() {
	local nic=$1
	[[ -z "$nic" ]] &&
		nics=$(ip route | awk '/default/{match($0,"dev ([^ ]+)",M); print M[1]}')
	for nic in $nics; do
		[[ -z "$(ip -d link show  dev $nic|sed -n 3p)" ]] && {
			break
		}
	done
	local ipaddr=`ip addr show $nic`;
	local ret=$(echo "$ipaddr" |
			awk '/inet .* global dynamic/{match($0,"inet ([0-9.]+)/[0-9]+",M); print M[1]}');
	echo "$ret"
}

#-------------------------------------------------------------------------------
echo -e "installing kiss-vm ..."
KissUrl=https://github.com/tcler/kiss-vm-ns
while true; do
	git clone --depth=1 "$KissUrl" && make -C kiss-vm-ns
	which vm && which netns && break
	sleep 5
	echo -e "{warn} installing kiss-vm  fail, try again ..."
done
vm prepare >/dev/null

echo -e "creating macvlan if mv-host-pub ..."
netns host,mv-host-pub,dhcp
ip a s dev mv-host-pub


#-------------------------------------------------------------------------------
protocol="http"
address="download.devel.red hat.com"
basepath="qa/rh ts/look aside/"
BaseUrl=${protocol// /}://${address// /}/${basepath// /}

read A B C D N < <(getDefaultIp4|sed 's;[./]; ;g')
HostIPSuffix=$(printf %02x%02x $C $D)
HostIPSuffixL=$(printf %02x%02x%02x%02x $A $B $C $D)
WinVmName=win2022-${HostIPSuffix}

if true; then
#-------------------------------------------------------------------------------
#WINVER=2019
#img_name=Win2019-Evaluation.iso
#os_variant=win2k19
WINVER=2022
img_name=Win2022-Evaluation.iso
os_variant=win2k22

openssh_url="$BaseUrl/windows-images/OpenSSH-Win64.zip"
img_url="$BaseUrl/windows-images/$img_name"
ADDomain=fsqe${HostIPSuffix}.redhat.com
ADPasswd=Sesame~0pen
vm create Windows-server -n ${WinVmName} -C $img_url --osv=$os_variant --dsize 50 \
	--win-auto=cifs-nfs --win-enable-kdc --win-openssh=$openssh_url \
	--win-domain=${ADDomain} --win-passwd=${ADPasswd} --force --wait
eval "$(< /tmp/${WinVmName}.env)"
[[ -z "$VM_INT_IP" || -z "$VM_EXT_IP" ]] && {
	echo "{ERROR} VM_INT_IP($VM_INT_IP) or VM_EXT_IP($VM_EXT_IP) of Windows VM is nil"
	exit 1
}

fi

#-------------------------------------------------------------------------------
pdir="Netapp-Simulator"
ovaImage=vsim-netapp-DOT9.11.1-cm_nodar.ova
licenseFile=CMode_licenses_9.11.1.txt
ImageUrl=${BaseUrl}/$pdir/$ovaImage
LicenseFileUrl=${BaseUrl}/$pdir/$licenseFile
script=ontap-simulator-two-node.sh
minram=$((15*1024))
singlenode=$1
[[ "$singlenode" = [sy]* ]] && {
	shift
	script=ontap-simulator-single-node.sh
	minram=$((8*1024 - 512))
}
ramsize=$(free -m|awk '/Mem:/{print $2}')
[[ "$ramsize" -le "$minram" ]] && {
	echo "{WARN} total ram size(${ramsize}m) on your system is not enough(>=$minram)"
	exit 1
}

wget -c --progress=dot:giga "$ImageUrl"
wget -c --progress=dot:giga "$LicenseFileUrl"

echo -e "installing ontap-simulator-in-kvm tool ..."
_url=https://github.com/tcler/ontap-simulator-in-kvm
while ! git clone --depth=1 $_url; do [[ -d ontap-simulator-in-kvm ]] && break || sleep 5; done

eval $(< /tmp/${WinVmName}.env)
NTP_SERVER=10.5.26.10
DNS_DOMAIN=${AD_DOMAIN}
DNS_ADDR=${VM_EXT_IP}
AD_HOSTNAME=${AD_FQDN}
AD_IP=${VM_EXT_IP}
AD_ADMIN=${ADMINUSER}
AD_PASS=${ADMINPASSWORD}
optx=(--ntp-server=$NTP_SERVER --dnsdomains=$DNS_DOMAIN --dnsaddrs=$DNS_ADDR \
	--ad-hostname=$AD_HOSTNAME --ad-ip=$AD_IP \
	--ad-admin=$AD_ADMIN --ad-passwd=$AD_PASS --ad-ip-hostonly "${VM_INT_IP}")
ONTAP_INSTALL_LOG=/tmp/ontap2-install.log
ONTAP_IF_INFO=/tmp/ontap2-if-info.txt
bash ontap-simulator-in-kvm/$script --image $ovaImage --license-file $licenseFile "${optx[@]}" &> >(tee $ONTAP_INSTALL_LOG)

tac $ONTAP_INSTALL_LOG | sed -nr '/^[ \t]+lif/ {:loop /\nfsqe-[s2]nc1/!{N; b loop}; p;q}' | tac >$ONTAP_IF_INFO

################################# Assert ################################
echo -e "Assert 1: ping windows ad server: $VM_EXT_IP ..." >/dev/tty
ping -c 4 $VM_EXT_IP || {
	[[ -n "$VM_INT_IP" ]] && {
		sshOpt="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
		ssh $sshOpt $AD_ADMIN@${VM_INT_IP} ipconfig
	}
	echo -e "Alert 1: ping windows ad server($VM_EXT_IP) fail"
	exit 1
}
################################# Assert ################################

#join host to ad domain(krb5 realm)
echo -e "join host to $AD_DOMAIN($AD_HOSTNAME) ..."
netbiosname=host-${HostIPSuffix}
 echo "$netbiosname $HOSTNAME" >/etc/host.aliases
 echo "export HOSTALIASES=/etc/host.aliases" >>/etc/profile
 source /etc/profile
config-ad-client.sh --addc_ip $VM_INT_IP --addc_ip_ext $VM_EXT_IP -p $AD_PASS --config_krb --enctypes AES --host-netbios $netbiosname

ONTAP_ENV_FILE=/tmp/ontap2info.env
nfsmp_krb5=/mnt/nfsmp-ontap-krb5
nfsmp_krb5i=/mnt/nfsmp-ontap-krb5i
nfsmp_krb5p=/mnt/nfsmp-ontap-krb5p
eval $(< $ONTAP_ENV_FILE)
clientip=$(getDefaultIp4 mv-host-pub)

################################# Assert ################################
echo -e "Assert 2: ping windows ad server: $VM_EXT_IP ..." >/dev/tty
ping -c 4 $VM_EXT_IP || {
	[[ -n "$VM_INT_IP" ]] && {
		sshOpt="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no"
		ssh $sshOpt $AD_ADMIN@${VM_INT_IP} ipconfig
	}
	echo -e "Alert 2: ping windows ad server($VM_EXT_IP) fail"
	exit 1
}
################################# Assert ################################

echo -e "\nhostname -A ..."
hostname -A

echo -e "\nhostname $netbiosname  #required by nfs krb5 mount ..."
hostname $netbiosname  #required by nfs krb5 mount

echo -e "\nnfs mount test ..."
run mkdir -p $nfsmp_krb5 $nfsmp_krb5i $nfsmp_krb5p
run mount $NETAPP_NAS_HOSTNAME:$NETAPP_NFS_SHARE2 $nfsmp_krb5 -osec=krb5,clientaddr=$clientip
run mount $NETAPP_NAS_HOSTNAME:$NETAPP_NFS_SHARE2 $nfsmp_krb5i -osec=krb5i,clientaddr=$clientip
run mount $NETAPP_NAS_HOSTNAME:$NETAPP_NFS_SHARE2 $nfsmp_krb5p -osec=krb5p,clientaddr=$clientip
run mount -t nfs4
run umount -a -t nfs4,nfs
