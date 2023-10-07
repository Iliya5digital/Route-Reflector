#!/bin/sh
# tags: debian10,debian11,ubuntu2004,ubuntu2204,alma8
RNAME=route_reflector

set -x

LOG_PIPE=/tmp/log.pipe.$$                                                                                                                                                                                                                    
mkfifo ${LOG_PIPE}
LOG_FILE=/root/${RNAME}.log
touch ${LOG_FILE}
chmod 600 ${LOG_FILE}

tee < ${LOG_PIPE} ${LOG_FILE} &

exec > ${LOG_PIPE}
exec 2> ${LOG_PIPE}

killjobs() {
    jops="$(jobs -p)"
    test -n "${jops}" && kill ${jops} || :
}
trap killjobs INT TERM EXIT

echo
echo "=== Recipe ${RNAME} started at $(date) ==="
echo

if [ -f /etc/redhat-release ]; then
    OSNAME=centos
else
    OSNAME=debian
fi

Service() {
    # $1 - name
    # $2 - command

    if [ -n "$(which systemctl 2>/dev/null)" ]; then
        systemctl ${2} ${1}.service
    else
        if [ "${2}" = "enable" ]; then
            if [ "${OSNAME}" = "debian" ]; then
                update-rc.d ${1} enable
            else
                chkconfig ${1} on
            fi
        else
            service ${1} ${2}
        fi
    fi
}

if [ "${OSNAME}" = "debian" ]; then
    export DEBIAN_FRONTEND="noninteractive"

    # Wait firstrun script
    while ps uxaww | grep  -v grep | grep -Eq 'apt-get|dpkg' ; do echo "waiting..." ; sleep 3 ; done
    apt-get update --allow-releaseinfo-change || :
    apt-get update
    test -f /usr/bin/which || apt-get -y install which
    which lsb_release 2>/dev/null || apt-get -y install lsb-release
    which logger 2>/dev/null || apt-get -y install bsdutils
    OSREL=$(lsb_release -s -c)
    apt install -y curl ca-certificates
    curl -s https://deb.frrouting.org/frr/keys.asc | apt-key add -
    FRRVER="frr-stable"
    echo deb https://deb.frrouting.org/frr $(lsb_release -s -c) $FRRVER | tee -a /etc/apt/sources.list.d/frr.list
    apt update
    apt -y install frr frr-pythontools
else
    OSREL=$(rpm -qf --qf '%{version}' /etc/redhat-release | cut -d . -f 1)
    FRRVER="frr-stable"
    yum install -y curl
    curl -O https://rpm.frrouting.org/repo/$FRRVER-repo-1-0.el8.noarch.rpm
    yum install -y ./$FRRVER*
    yum install -y frr frr-pythontools
fi

sed -i '/bgpd=/s/no/yes/' /etc/frr/daemons
CONFIG="/etc/frr/frr.conf"
ip=$(ip route get 1 | grep -Po '(?<=src )[^ ]+')
if grep -q "router bgp" $CONFIG; then
    # Already exists. adding new neighbor or new network
    if grep -q "($NEIGHBOR)" $CONFIG; then
        # This neighbor already exists
        true
    else
        sed -i "/extended-nexthop/a    neighbor ($NEIGHBOR) peer-group fabric" $CONFIG
        sed -i "/extended-nexthop/a    neighbor ($NEIGHBOR) remote-as ($AS)" $CONFIG
    fi
    if [ "($VXLAN)" = "yes" ]; then
        # need to add vxlan?
        if grep -q "address-family l2vpn evpn" $CONFIG; then
            # already enabled
            true
        else
            sed -i '/exit-address-family/cexit-address-family\
    !\
    address-family l2vpn evpn\
        neighbor fabric activate\
        neighbor fabric route-reflector-client\
        advertise-all-vni\
    exit-address-family' $CONFIG
        fi
    fi
    if grep -q "($PREFIX)" $CONFIG; then
        # already added
        true
    else
        if ! [ "($PREFIX)" = "()" ]; then
            cat << EOF >> $CONFIG
ip prefix-list IPV4_PLIST permit ($PREFIX) ge 32 le 32
!
EOF
        fi
    fi
else
    cat << EOF > $CONFIG
router bgp ($AS)
    bgp router-id $ip
    bgp log-neighbor-changes
    no bgp default ipv4-unicast
    neighbor fabric peer-group
    neighbor fabric capability extended-nexthop
    neighbor ($NEIGHBOR) remote-as ($AS)
    neighbor ($NEIGHBOR) peer-group fabric
    !
    address-family ipv4 unicast
        neighbor fabric activate
        neighbor fabric route-map IPV4_IMPORT in
        neighbor fabric route-reflector-client
    exit-address-family
    !
EOF
    if [ "($VXLAN)" = "yes" ]; then
        cat << EOF >> $CONFIG
    address-family l2vpn evpn
        neighbor fabric activate
        neighbor fabric route-reflector-client
        advertise-all-vni
    exit-address-family
EOF
    fi
    cat << EOF >> $CONFIG
exit
!
route-map IPV4_IMPORT permit 5
    match ip address prefix-list IPV4_PLIST
exit
!
ip nht resolve-via-default
!
EOF
if ! [ "($PREFIX)" = "()" ]; then
    cat << EOF >> $CONFIG
ip prefix-list IPV4_PLIST permit ($PREFIX) ge 32 le 32
!
EOF
    fi
    Service frr enable
fi
sed -i '/Nice/d' /usr/lib/systemd/system/frr.service
sed -i '/Nuce/d' /lib/systemd/system/frr.service
systemctl daemon-reload
Service frr restart
