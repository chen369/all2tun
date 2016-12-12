#!/bin/sh



#!/bin/bash
socks_server=127.0.0.1:8080

id="$RANDOM"
tun="$(printf 'tun%04x' "$id")"
ip tuntap add dev $tun mode tun
ip link set $tun up
ip addr add 169.254.1.1/30 dev $tun
sysctl -w net.ipv4.conf.$tun.forwarding=1
ip rule add fwmark $id lookup $id
ip route add default via 169.254.1.2 table $id
iptables -t mangle -I PREROUTING -i eth1 -p tcp -j MARK --set-mark $id
iptables -t mangle -I PREROUTING -i eth2 -p tcp -j MARK --set-mark $id
badvpn-tun2socks --tundev $tun --netif-ipaddr 169.254.1.2 --netif-netmask 255.255.255.252 --socks-server-addr $socks_server

iptables -t mangle -D PREROUTING -i eth2 -p tcp -j MARK --set-mark $id
iptables -t mangle -D PREROUTING -i eth1 -p tcp -j MARK --set-mark $id
ip route del default via 169.254.1.2 table $id
ip rule del from fwmark $id lookup $id
ip tuntap del dev $tun mode tun


######################################################################################
# version 0.05
# 
# ToDo: 
#	0) create description here
#	1) ssh agent for key passphrase storage
#	2) ssh config for auto "yes" to "continue to connection" questions
#	3) key fingerprint to check
#	4) config file for the fingerprint, IP and (maybe) other stuff storing
#	5) "debug mode" and "silent mode"
#	6) to be ready for starting from crontab
#	7) need to check if addr is absent and stop with error exit code
#	*) to understand - what about IPv6 ?
#	?) ...
# 
######################################################################################

CON_FILE="/etc/NetworkManager/system-connections/Wired connection 1"
SSH_KEY="keyfile"
UDPGW_FILE="udpgw"
TUN2SOCKS_FILE="tun2socks"
DNS_SERV="8.8.8.8"
TUN_DEV="tun0"
TUN_IP="10.10.0.1"
TUN_GW="10.10.0.2"
TUN_MASK="255.255.255.0"
TUN_USER="nobody"
SERVER_PORT="443"
SOCKS_PORT="5350"
UDPGW_REMOTE_SERVER_PORT="7300"

# you outside connection gateway
ORIGINAL_GW="10.0.2.2"

if [ -z "$1" ] || [ $(id -u) -ne 0 ]
then
  echo "usage: sudo `basename $0` server_addr or IP [-u for udpgw upload to the sever]\n if you need to change something else - go inside and edit variables and the code :)"
  exit $E_BADARGS
fi

#echo "$(dirname $0)"
cd $(dirname $0)

if echo $1 | grep -E "^[0-9]{1,3}(\.[0-9]{1,3}){3}$" > /dev/null
then
	SERVER_IP=$1
else
	SERVER_IP=$(nslookup $1 | grep "Address: " | cut -d " " -f 2 -s)
fi

echo "addr=$SERVER_IP"

sed -i '$G' "$CON_FILE"
sed -i "/^\[ipv4\]/!b;:x;n;/^dns="$DNS_SERV";$/b;s/^dns=/dns="$DNS_SERV";/;t;/^[[:space:]]*$/s/^/dns="$DNS_SERV";\n/;t;bx" "$CON_FILE"
sed -i "/^\[ipv4\]/!b;:x;n;s/^ignore-auto-dns=.*/ignore-auto-dns=true/;t;/^[[:space:]]*$/s/^/ignore-auto-dns=true\n/;t;bx" "$CON_FILE"
sed -i '$d' "$CON_FILE"

SERVER_CMD="/tmp/$UDPGW_FILE --listen-addr 127.0.0.1:$UDPGW_REMOTE_SERVER_PORT &"

if [ "$2" = "-u" ]
then
	echo "udpgw will be uploaded to the server and started"
	su -s /bin/sh $TUN_USER -c "scp -i $SSH_KEY -P $SERVER_PORT $UDPGW_FILE root@$SERVER_IP:/tmp/"
	su -s /bin/sh $TUN_USER -c "ssh -i $SSH_KEY root@$SERVER_IP -p $SERVER_PORT $SERVER_CMD"
fi


if ip tuntap show | grep "$TUN_DEV: tun"
# > /dev/null
then
	echo "tun device $TUN_DEV already exist"
else
	ip tuntap add dev $TUN_DEV mode tun user $TUN_USER
fi

ifconfig $TUN_DEV $TUN_IP netmask $TUN_MASK

SSH_CMDLN="ssh -i $SSH_KEY -fNC -D localhost:$SOCKS_PORT root@$SERVER_IP -p $SERVER_PORT -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no"
#SSH_CMDLN="ssh -fNC -D localhost:$SOCKS_PORT root@$SERVER_IP -p $SERVER_PORT -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes"
if pgrep -xf "$SSH_CMDLN" 
then
	echo "ssh tunnel already exist"
else
	echo "ssh tunnel will be started"
	su -s /bin/sh $TUN_USER -c "$SSH_CMDLN"
fi
echo "$? ****"

TUN2SOCKS_CMDLN="$TUN2SOCKS_FILE --tundev $TUN_DEV --netif-ipaddr $TUN_GW --netif-netmask $TUN_MASK --socks-server-addr 127.0.0.1:$SOCKS_PORT --udpgw-remote-server-addr 127.0.0.1:$UDPGW_REMOTE_SERVER_PORT 1>/dev/null &"

#2>&1 &"

pkill -x $TUN2SOCKS_FILE
#ps -AFww | grep $TUN2SOCKS_FILE

su -s /bin/sh $TUN_USER -c "./$TUN2SOCKS_CMDLN"
echo "$? *****"

ip route replace $SERVER_IP via $ORIGINAL_GW metric 5
ip route del default
ip route add default via $TUN_GW metric 6

cd - >/dev/null

