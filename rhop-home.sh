#!/bin/bash
export XRAYVER="--version v26.3.27"
set -o pipefail

DRY_RUN=0
NAME=""
for arg in "$@"; do
	case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		*) NAME="$arg" ;;
	esac
done
[[ -z "$NAME" ]] && NAME=default

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
	echo "This script must be run as root"
	exit 1
fi

if [[ -z "$TUNNEL_SEED" || -z "$HOST" ]]; then
	echo "需要设置环境变量 TUNNEL_SEED 和 HOST，例如："
	echo "TUNNEL_SEED=xxxx HOST=1.2.3.4 bash rhop-home.sh US13"
	exit 1
fi

# 检查安装位置不是 CN
if [[ $DRY_RUN -eq 0 ]]; then
	COUNTRYCODE=$(curl -4 -s https://dash.cloudflare.com/cdn-cgi/trace | grep '^loc=' | cut -d= -f2)
	if [[ -z "$COUNTRYCODE" ]]; then
		echo "无法获取安装位置国家代码，终止安装"
		exit 1
	fi
	if [[ "$COUNTRYCODE" == "CN" ]]; then
		echo "安装位置为中国大陆 (CN)，终止安装"
		exit 1
	fi
fi

# 安装 Xray
if [[ $DRY_RUN -eq 0 && ! -f /usr/local/bin/xray ]]; then
	bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install  --without-geodata $XRAYVER
fi

TUNNEL_HEX=$(echo -n "$TUNNEL_SEED" | md5sum | cut -c1-6)
TUNNEL_PORT=$(((16#$TUNNEL_HEX % 20000) + 40000))

if [[ -x /usr/local/bin/xray ]]; then
	TUNNEL_UUID=$(/usr/local/bin/xray uuid -i "$TUNNEL_SEED")
else
	TUNNEL_UUID_HASH=$(echo -n "$TUNNEL_SEED" | md5sum | cut -d' ' -f1)
	TUNNEL_UUID="${TUNNEL_UUID_HASH:0:8}-${TUNNEL_UUID_HASH:8:4}-${TUNNEL_UUID_HASH:12:4}-${TUNNEL_UUID_HASH:16:4}-${TUNNEL_UUID_HASH:20:12}"
fi

# 开启 BBR
if [[ $DRY_RUN -eq 0 ]]; then
	sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
	sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
	echo "net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.conf
	echo "net.core.default_qdisc = fq" >>/etc/sysctl.conf
	sysctl -p >/dev/null 2>&1
fi

render_config() {
cat <<EOF
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
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["bridge"], "domain": ["full:reverse.proxy"], "outboundTag": "interconn" },
      { "type": "field", "inboundTag": ["bridge"], "ip": ["10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.0.2.0/24","192.168.0.0/16","198.18.0.0/15","198.51.100.0/24","203.0.113.0/24","224.0.0.0/4","240.0.0.0/4","255.255.255.255/32","::/128","::1/128","fc00::/7","fe80::/10","ff00::/8"], "outboundTag": "block" },
      { "type": "field", "inboundTag": ["bridge"], "outboundTag": "out" }
    ]
  }
}
EOF
}

if [[ $DRY_RUN -eq 1 ]]; then
	if [[ ! -x /usr/local/bin/xray ]]; then
		echo "警告：未找到 xray，以下 UUID 为基于 TUNNEL_SEED 的占位符" >&2
	fi
	render_config
	echo "" >&2
	echo "Dry-run 完成，未做任何更改" >&2
	exit 0
fi

TS=$(date +%s)
CONF="/usr/local/etc/xray/${NAME}.json"
[[ -f "$CONF" ]] && mv "$CONF" "${CONF}.${TS}.bak"

render_config >"$CONF"

systemctl enable "xray@${NAME}" --now
systemctl restart "xray@${NAME}"
systemctl status "xray@${NAME}" --no-pager -l

echo ""
echo "Bridge 已安装"
echo "配置文件: ${CONF}   服务: xray@${NAME}"
