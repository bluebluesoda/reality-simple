#!/bin/bash
export XRAYVER="--version v25.5.16"
set -o pipefail

NAME=$1
[[ -z "$NAME" ]] && NAME=default

if [[ $EUID -ne 0 ]]; then
	echo "This script must be run as root"
	exit 1
fi

# 仅支持 Debian/Ubuntu
if [[ ! -f /etc/debian_version ]]; then
	echo "This script is designed for Debian/Ubuntu systems only."
	exit 1
fi

if [[ -z "$TUNNEL_SEED" || -z "$HOST" ]]; then
	echo "需要设置环境变量 TUNNEL_SEED 和 HOST，例如："
	echo "TUNNEL_SEED=xxxx HOST=1.2.3.4 bash rhop-home.sh US13"
	exit 1
fi

apt-get update
apt-get install -y unzip curl

# 安装 Xray
if [[ ! -f /usr/local/bin/xray ]]; then
	bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install  --without-geodata $XRAYVER
fi

TUNNEL_HEX=$(echo -n "$TUNNEL_SEED" | md5sum | cut -c1-6)
TUNNEL_PORT=$(((16#$TUNNEL_HEX % 20000) + 40000))
TUNNEL_UUID=$(xray uuid -i "$TUNNEL_SEED")

# 开启 BBR
sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
sysctl -p >/dev/null 2>&1

TS=$(date +%s)
CONF="/usr/local/etc/xray/${NAME}.json"
[[ -f "$CONF" ]] && mv "$CONF" "${CONF}.${TS}.bak"

cat >"$CONF" <<-EOF
	{
	  "log": { "loglevel": "warning" },
	  "reverse": {
	    "bridges": [
	      { "tag": "bridge", "domain": "reverse.proxy" }
	    ]
	  },
	  "outbounds": [
	    {
	      "tag": "interconn",
	      "protocol": "vless",
	      "settings": {
	        "vnext": [
	          {
	            "address": "${HOST}",
	            "port": ${TUNNEL_PORT},
	            "users": [
	              { "id": "${TUNNEL_UUID}", "encryption": "none" }
	            ]
	          }
	        ]
	      },
	      "streamSettings": { "network": "tcp" }
	    },
	    {
	      "protocol": "freedom",
	      "settings": { "domainStrategy": "UseIPv4v6" },
	      "tag": "out"
	    },
	    {
	      "protocol": "blackhole",
	      "tag": "block"
	    }
	  ],
	  "routing": {
	    "domainStrategy": "AsIs",
	    "rules": [
	      { "type": "field", "inboundTag": ["bridge"], "domain": ["full:reverse.proxy"], "outboundTag": "interconn" },
	      { "type": "field", "inboundTag": ["bridge"], "ip": ["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","127.0.0.0/8","169.254.0.0/16","fc00::/7","fe80::/10","::1/128"], "outboundTag": "block" },
	      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "out" }
	    ]
	  }
	}
EOF

systemctl enable "xray@${NAME}" --now
systemctl restart "xray@${NAME}"
systemctl status "xray@${NAME}" --no-pager -l

echo ""
echo "Bridge 已安装"
echo "配置文件: ${CONF}   服务: xray@${NAME}"
