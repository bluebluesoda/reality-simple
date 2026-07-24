#!/bin/bash
# @author Who care
# @since 2024-10-21
# @description Reality One-click Installer Lite
BASEURL="https://raw.githubusercontent.com/bluebluesoda/reality-simple/refs/heads/main/"
export XRAYVER="--version v25.5.16"
export CI=1
export AUTOMATION=1
QDISC="cake"

# 系统识别
OS_FAMILY=""
if [[ -f /etc/debian_version ]]; then
	OS_FAMILY="debian"
elif [[ -f /etc/os-release ]]; then
	# shellcheck disable=SC1091
	source /etc/os-release
	if [[ "$ID" =~ ^(rocky|almalinux|rhel|centos)$ || "$ID_LIKE" == *rhel* ]]; then
		OS_FAMILY="rhel"
	fi
fi

if [[ -z "$OS_FAMILY" ]]; then
	echo "此脚本仅在 Debian Ubuntu Rocky AlmaLinux 上测试过，其他系统将退出安装"
	exit 1
fi

if [ $(uname -r | cut -d. -f1) -lt 5 ]; then
    QDISC="fq"
fi

# 包管理器封装
if [[ "$OS_FAMILY" == "debian" ]]; then
	PKG_MANAGER="apt-get"
else
	if command -v dnf >/dev/null 2>&1; then
		PKG_MANAGER="dnf"
	else
		PKG_MANAGER="yum"
	fi
fi

pkg_update() {
	if [[ "$OS_FAMILY" == "debian" ]]; then
		apt-get update
	else
		$PKG_MANAGER makecache -y >/dev/null 2>&1 || true
	fi
}

pkg_install() {
	if [[ "$OS_FAMILY" == "debian" ]]; then
		apt-get install -y "$@"
	else
		$PKG_MANAGER install -y "$@"
	fi
}

if [[ $EUID -ne 0 ]]; then
	echo "此简易脚本仅限 root 用户运行"
	exit 1
fi

SEED=${SEED:-$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)}
PORT=${PORT:-"443"}
HOST=${HOST:-""}
CADDYFILE=1 #是否覆写caddyfile

if [[ $1 == "@keep-caddyfile" ]]; then
	CADDYFILE=0
fi

[[ "$(awk '/^MemTotal:/{print $2}' /proc/meminfo)" -lt $((400 * 1024)) ]] && echo "系统内存小于512M，可能导致安装失败"

# 获取基本网络信息
TRACE4=$(curl -4 -s https://dash.cloudflare.com/cdn-cgi/trace)
TRACE6=$(curl -6 -s https://dash.cloudflare.com/cdn-cgi/trace)
if [[ -z "$TRACE4" ]]; then
	echo "无IPv4网络连接，简易脚本无法处理"
	exit 1
fi
WARP4=$(echo "$TRACE4" | grep '^warp=' | cut -d= -f2)
WARP6=$(echo "$TRACE6" | grep '^warp=' | cut -d= -f2)
if [[ "$WARP4" == "off" ]]; then
	IPV4=$(echo "$TRACE4" | grep '^ip=' | cut -d= -f2)
else
	echo "请关闭WARP后再运行此脚本"
	exit 1
fi
if [[ "$WARP6" == "off" ]]; then
	IPV6=$(echo "$TRACE6" | grep '^ip=' | cut -d= -f2)
fi
TS=$(echo "$TRACE4" | grep '^ts=' | cut -d= -f2 | cut -d. -f1)

###### SNI配置
# 检查IPv4是否在本机网卡上
check_ipv4_on_interface() {
	local ip="$1"
	[[ -z "$ip" ]] && return 1
	ip a | grep -q "inet ${ip}/"
	return $?
}
# 颜色定义
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
NC='\033[0m' # No Color

# 域名格式验证函数
is_valid_domain() {
	local domain="$1"

	# 确保域名以字母结尾
	[[ ! "$domain" =~ [a-zA-Z]$ ]] && return 1

	IFS='.' read -ra parts <<<"$domain"
	[[ ${#parts[@]} -lt 2 ]] && return 1
	for part in "${parts[@]}"; do
		[[ -z "$part" ]] && return 1
		[[ "$part" == -* || "$part" == *- ]] && return 1
		if ! [[ "$part" =~ ^[a-zA-Z0-9-]+$ ]]; then
			return 1
		fi
	done
	return 0
}

# DNS解析验证函数
check_dns_match() {
	local domain="$1"

	# 获取完整JSON响应
	local response_a=$(curl -s "https://dns.google/resolve?name=${domain}&type=A")
	local response_aaaa=$(curl -s "https://dns.google/resolve?name=${domain}&type=AAAA")

	local dns_ipv4=$(echo "$response_a" | grep -o '"Answer":\[.*\]' | grep -oP '"data":"\K[^"]+' | head -1)
	local dns_ipv6=$(echo "$response_aaaa" | grep -o '"Answer":\[.*\]' | grep -oP '"data":"\K[^"]+' | head -1)

	if { [[ -z "$dns_ipv4" && -n "$dns_ipv6" && "$dns_ipv6" == "$IPV6" ]] ||
		[[ -z "$dns_ipv6" && -n "$dns_ipv4" && "$dns_ipv4" == "$IPV4" ]] ||
		[[ -n "$dns_ipv4" && -n "$dns_ipv6" && "$dns_ipv4" == "$IPV4" && "$dns_ipv6" == "$IPV6" ]]; }; then
		return 0
	fi
	return 1
}

# 生成随机域名
generate_random_domain() {
	local default_sni=""
	local response http_code cleaned

	# 获取 3 个随机单词
	response=$(curl -s --max-time 3 -w "\n%{http_code}" "http://random-word-api.herokuapp.com/word?number=3" 2>/dev/null)
	http_code=$(echo "$response" | tail -n1)
	response=$(echo "$response" | head -n-1)

	if [[ "$http_code" == "200" ]] && [[ -n "$response" ]]; then
		# 过滤掉多余字符，只保留小写字母和逗号 (例如从 ["a","b","c"] 变成 a,b,c)
		cleaned=$(echo "$response" | tr -cd 'a-z,')
		
		# 将字符串按逗号分割存入数组
		IFS=',' read -r -a words <<< "$cleaned"

		# 确保成功获取了至少 3 个有效单词
		if [[ ${#words[@]} -ge 3 ]] && [[ -n "${words[0]}" ]] && [[ -n "${words[1]}" ]] && [[ -n "${words[2]}" ]]; then
			default_sni="${words[0]}.${words[1]}${words[2]}.net"
		else
			default_sni="api.$((RANDOM + RANDOM + RANDOM)).com"
		fi
	else
		default_sni="api.$((RANDOM + RANDOM + RANDOM)).com"
	fi
	
	echo "$default_sni"
}

# 显示SNI状态
show_sni_status() {
	local sni="$1"
	local cert_type="$2"
	local color="$3"

	echo "使用：${sni}"
	echo -e "签名：${color}${cert_type}${NC}"
	echo "------"
}

# 处理SNI设置的主逻辑
handle_sni_setup() {
    local first_run=true
    local proposed_sni=""
    local cert_type=""
    local color=""
    local autotls_value=""
    local physical_ipv4=""

    # 1. 在循环前进行一次前置物理网卡IPv4检测和标记
    if [[ -n "$IPV4" ]] && check_ipv4_on_interface "$IPV4"; then
        physical_ipv4="$IPV4"
    fi

    while true; do
        # 首次运行时尝试自动生成
        if [[ "$first_run" == true ]]; then
            first_run=false
            echo "未设置SNI，自动生成SNI中"

            # 尝试使用标记好的物理IP
            if [[ -n "$physical_ipv4" ]]; then
                proposed_sni="$physical_ipv4"
                cert_type="自动"
                color="$GREEN"
                autotls_value="tls {
    issuer acme {
      profile shortlived
    }
  }"
            else
                # 回落到随机域名
                proposed_sni=$(generate_random_domain)
                cert_type="自签"
                color="$ORANGE"
                autotls_value="tls internal"
            fi

            show_sni_status "$proposed_sni" "$cert_type" "$color"
        fi

        # 获取用户输入
        read -rp "回车确认或输入其他SNI: " user_input
        # 去除首尾空格并转小写 (使用sed处理空格更严谨)
        user_input=$(echo "$user_input" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | tr '[:upper:]' '[:lower:]')

        # 用户直接回车，使用建议值
        if [[ -z "$user_input" ]]; then
            SNI="$proposed_sni"
            AUTOTLS="$autotls_value"
            if [[ "$cert_type" == "自动" && "$proposed_sni" != "$physical_ipv4" ]]; then
                [[ -z "$HOST" ]] && HOST="$SNI"
            fi
            break
        fi

        # 2. 特殊拦截：如果输入完美等于物理IPv4，直接应用IPv4规则，跳过域名验证
        if [[ -n "$physical_ipv4" && "$user_input" == "$physical_ipv4" ]]; then
            proposed_sni="$physical_ipv4"
            cert_type="自动"
            color="$GREEN"
            autotls_value="tls {
    issuer acme {
      profile shortlived
    }
  }"
            show_sni_status "$proposed_sni" "$cert_type" "$color"
            continue # 返回循环起点，等待用户回车确认
        fi

        # 用户输入了新SNI，验证格式
        if ! is_valid_domain "$user_input"; then
            echo "SNI不合法，请重新抉择"
            echo "已设置回 $proposed_sni"
            continue
        fi

        # 格式合法，检查DNS并更新proposed_sni
        proposed_sni="$user_input"
        if check_dns_match "$proposed_sni"; then
            cert_type="自动"
            color="$GREEN"
            autotls_value=""
        else
            cert_type="自签"
            color="$ORANGE"
            autotls_value="tls internal"
        fi
        show_sni_status "$proposed_sni" "$cert_type" "$color"
    done
}

# 主流程
if [[ -z "$SNI" ]]; then
	# 用户未设置SNI，进入交互流程
	handle_sni_setup
else
	# 用户已设置SNI
	SNI=$(echo "$SNI" | tr '[:upper:]' '[:lower:]')
	if [[ "$SNI" == "rawip" ]]; then
		# 特殊关键字rawip
		if [[ -n "$IPV4" ]] && check_ipv4_on_interface "$IPV4"; then
			SNI="$IPV4"
			AUTOTLS="tls {
    issuer acme {
      profile shortlived
    }
  }"
		else
			# 回落到交互设置
			echo "SNI不合理，请重新设置"
			unset SNI
			handle_sni_setup
		fi
	else
		# 用户设置了具体的SNI值
		if ! is_valid_domain "$SNI"; then
			# 格式不合法，回落到交互设置
			echo "SNI不合理，请重新设置"
			unset SNI
			handle_sni_setup
		else
			# 格式合法，检查DNS
				if check_dns_match "$SNI"; then
					# DNS匹配成功，自动证书
					AUTOTLS=""
					[[ -z "$HOST" ]] && HOST="$SNI"
				else
					# DNS不匹配，自签证书
					AUTOTLS="tls internal"
				fi
		fi
	fi
fi
###### SNI配置结束

###### Swap 配置
setup_swap() {
	local total_mem_kb
	total_mem_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
 
	# 内存大于1.5G无需考虑swap流程
	if [[ -n "$total_mem_kb" && "$total_mem_kb" -gt $((1400 * 1024)) ]]; then
		return
	fi
 
	local active_swap
	active_swap=$(swapon --show=NAME --noheadings 2>/dev/null)
 
	if [[ -n "$active_swap" ]]; then
		return
	fi
 
	# 清理 /etc/fstab 中未启用的 swap 条目
	if [[ -f /etc/fstab ]] && grep -qE '(^|\s)swap(\s|$)' /etc/fstab; then
		cp /etc/fstab /etc/fstab.$TS.bak
		while IFS= read -r line; do
			[[ -z "$line" || "$line" =~ ^# ]] && continue
			local swap_target
			swap_target=$(echo "$line" | awk '{print $1}')
			# 仅当目标是一个普通文件时才物理删除；swap分区/设备保留不动
			if [[ -f "$swap_target" ]]; then
				rm -f "$swap_target"
				echo "已删除未启用的swap文件: $swap_target"
			fi
		done < <(grep -E '(^|\s)swap(\s|$)' /etc/fstab)
 
		sed -i '/\sswap\s/d' /etc/fstab
		echo "已清理 /etc/fstab 中未启用的swap条目 (备份于 /etc/fstab.$TS.bak)"
	fi
 
	# 创建全新的 512M swap 文件
    local swapfile="/swapfile"
    [[ -f "$swapfile" ]] && rm -f "$swapfile"

    if command -v fallocate >/dev/null 2>&1 && fallocate -l 512M "$swapfile" 2>/dev/null; then
    	:
    else
	    dd if=/dev/zero of="$swapfile" bs=1M count=512 status=none
    fi

    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
    swapon "$swapfile"

    if ! grep -qE "^${swapfile}\s" /etc/fstab 2>/dev/null; then
	    echo "${swapfile} none swap sw 0 0" >>/etc/fstab
    fi
}
 
setup_swap

HEX_PART=$(echo -n "$SEED" | md5sum | cut -c1-6)
tmpport=$((16#$HEX_PART))
CADDYPORT=$(((tmpport % 30000) + 10000))

# 如果AUTOTLS包含关键词shortlived
if [[ "$AUTOTLS" == *"shortlived"* ]]; then
	DEST="$SNI:$CADDYPORT"
elif [[ "$AUTOTLS" == "tls internal" ]]; then
	CADDYPORT=444
	BINDLOCAL="bind 127.0.0.1 [::1]"
	DEST="127.0.0.1:$CADDYPORT"
else
	DEST="127.0.0.1:$CADDYPORT"
fi

warning000="Caddy listen on $DEST"

# 安装基础组件和caddy
if [[ "$CADDYFILE" -eq 1 ]] || ! command -v caddy >/dev/null 2>&1; then
	if [[ -f /etc/caddy/Caddyfile ]]; then
		mv /etc/caddy/Caddyfile /etc/caddy/Caddyfile.$TS.bak
		warning001="Backup of previous Caddyfile created at /etc/caddy/Caddyfile.$TS.bak"
	fi

	if ! command -v caddy >/dev/null 2>&1; then
		if [[ "$OS_FAMILY" == "debian" ]]; then
			echo "deb [trusted=yes] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" >/etc/apt/sources.list.d/caddy-stable.list
			apt-get update
			apt-get install -y caddy
		else
			# Rocky/AlmaLinux: 通过官方 COPR 仓库安装 caddy
			$PKG_MANAGER install -y 'dnf-command(copr)'
			$PKG_MANAGER copr enable -y @caddy/caddy
			$PKG_MANAGER install -y caddy
		fi
	fi

	# Caddyfile
	cat >/etc/caddy/Caddyfile <<-EOF
		{
		        skip_install_trust
		        auto_https disable_redirects
		        servers {
		                protocols h1 h2
		        }
		}

		https://${SNI}:${CADDYPORT} {
		    ${AUTOTLS}
		    ${BINDLOCAL} 
		    respond 404
		}
	EOF
	caddy fmt --overwrite /etc/caddy/Caddyfile
	systemctl enable caddy
	systemctl restart caddy
fi

pkg_update
if [[ "$OS_FAMILY" == "rhel" ]]; then
	# EPEL 提供 qrencode / jq 等包
	$PKG_MANAGER install -y epel-release
	pkg_update
	pkg_install unzip qrencode vim-common jq bind-utils
else
	pkg_install unzip qrencode xxd jq dnsutils
	apt-get clean
fi

# Install Xray
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --without-geodata $XRAYVER

UUID=$(xray uuid -i $SEED)

# Deriving public and private keys.
priv_hex=$(echo -n "$SEED" | sha256sum | cut -c1-64)
priv_b64=$(echo "$priv_hex" | xxd -r -p | base64 | tr '+/' '-_' | tr -d '=')
tmp_key=$(xray x25519 -i "$priv_b64")
private_key=$(printf '%s\n' "$tmp_key" | awk -F': ' '/^Private key:/ {print $2}')
public_key=$(printf '%s\n' "$tmp_key" | awk -F': ' '/^Public key:/ {print $2}')
USERSEC=$(echo -n "$SEED" | sha256sum | xxd -r -p | base64 | head -c 12)

args=("$@")
# Generate guest accounts if needed
if [[ ${#args[@]} -gt 0 ]]; then
	guests=""
	for arg in "${args[@]}"; do
		if [[ ${#arg} -gt 18 ]]; then
			echo "参数${arg}过长"
			exit 1
		fi

		if [[ "$arg" == "@keep-caddyfile" ]]; then
			continue
		fi

		guest_uuid=$(xray uuid -i "${arg}${USERSEC}")
		guests+=", { \"id\": \"${guest_uuid}\", \"email\": \"${arg}\", \"flow\": \"xtls-rprx-vision\" }"
	done
fi

###### SOCKS5 出站配置
#   带认证:  SOCKS5=user:pass@host:port
#   无认证:  SOCKS5=host:port
SOCKS5=${SOCKS5:-""}
SOCKS5_OUTBOUND=""   # 注入到 config.json outbounds 数组的片段（含结尾逗号）

if [ -n "$SOCKS5" ]; then
	PROXY_BODY="$SOCKS5"
	SP_USER=""
	SP_PASS=""
	SP_ADDR=""

	# 1) 拆认证与地址：主机名不含 @，故以最后一个 @ 为界
	case "$PROXY_BODY" in
		*@*)
			SP_CRED="${PROXY_BODY%@*}"     # @ 之前
			SP_ADDR="${PROXY_BODY##*@}"    # @ 之后
			SP_USER="${SP_CRED%%:*}"       # user:pass，以第一个 : 为界
			case "$SP_CRED" in
				*:*) SP_PASS="${SP_CRED#*:}" ;;
				*)   SP_PASS="" ;;
			esac
			;;
		*)
			SP_ADDR="$PROXY_BODY"
			;;
	esac

	# 2) 解析地址部分（IPv4 / 域名 / [IPv6]）
	SP_SERVER=""
	SP_PORT=""
	SP_ADDR_OK=1

	case "$SP_ADDR" in
		\[*\]:*)
			# [IPv6]:port —— 提取括号内地址与端口
			SP_HOSTPART="${SP_ADDR%%]*}"   # 形如 [2001:db8::1
			SP_SERVER="${SP_HOSTPART#\[}"  # 去掉开头的 [  ==> 裸 IPv6，写入 xray 不带括号
			SP_PORT="${SP_ADDR##*]:}"      # ] 之后、: 之后的端口
			;;
		\[*)
			# 有左括号但缺少 ]:port，格式错误
			SP_ADDR_OK=0
			;;
		*)
			# 非括号形式：统计冒号数量
			SP_TMP="${SP_ADDR//:/}"
			SP_COLON=$(( ${#SP_ADDR} - ${#SP_TMP} ))
			if [ "$SP_COLON" -eq 1 ]; then
				# 恰好一个冒号：host:port（IPv4 或域名）
				SP_SERVER="${SP_ADDR%:*}"
				SP_PORT="${SP_ADDR##*:}"
			else
				# 0 个冒号（缺端口）或多个冒号（裸 IPv6，必须加括号）
				SP_ADDR_OK=0
			fi
			;;
	esac

	# 3) 端口数字与范围校验（纯 POSIX，避免 [[ ]] / =~）
	SP_PORT_OK=0
	case "$SP_PORT" in
		'' | *[!0-9]*) SP_PORT_OK=0 ;;
		*)
			if [ "$SP_PORT" -ge 1 ] && [ "$SP_PORT" -le 65535 ]; then
				SP_PORT_OK=1
			fi
			;;
	esac

	# 4) 汇总校验并生成出站片段
	if [ "$SP_ADDR_OK" -ne 1 ] || [ -z "$SP_SERVER" ] || [ "$SP_PORT_OK" -ne 1 ]; then
		echo "SOCKS5 变量格式错误。支持 user:pass@host:port、host:port；IPv6 必须写成 [addr]:port。已忽略此设置"
	else
		if [ -n "$SP_USER" ]; then
			SP_USERS_JSON=", \"users\": [ { \"user\": \"${SP_USER}\", \"pass\": \"${SP_PASS}\" } ]"
		else
			SP_USERS_JSON=""
		fi
		# 作为 outbounds 数组的第一个元素（默认出站），结尾带逗号
		# 注意：address 为裸地址，IPv6 不带方括号（xray 要求）
		SOCKS5_OUTBOUND="{
        \"protocol\": \"socks\",
        \"tag\": \"socks-out\",
        \"settings\": {
          \"servers\": [
            { \"address\": \"${SP_SERVER}\", \"port\": ${SP_PORT}${SP_USERS_JSON} }
          ]
        }
      },"
		echo "已启用 SOCKS5 出站代理: ${SP_SERVER} 端口 ${SP_PORT}"
	fi
fi
###### SOCKS5 出站配置结束

# Xray config.json
if [[ -f /usr/local/etc/xray/config.json ]]; then
	mv /usr/local/etc/xray/config.json /usr/local/etc/xray/config.json.$TS.bak
	warning002="Backup of previous config.json created at /usr/local/etc/xray/config.json.$TS.bak"
fi

cat >/usr/local/etc/xray/config.json <<-EOF
	{
	  "log": {
	    "access": "none",
	    "error": "/var/log/xray/error.log",
	    "loglevel": "warning"
	  },
	  "stats": {},
	  "policy": {
	    "levels": {
	      "0": {
	        "statsUserUplink": true,
	        "statsUserDownlink": true
	      }
	    },
	    "system": {
	      "statsInboundUplink": true,
	      "statsInboundDownlink": true
	    }
	  },
	  "api": {
	    "tag": "api",
	    "services": ["StatsService"]
	  },
	  "inbounds": [
	    {
	      "listen": "0.0.0.0",
	      "port": ${PORT},
	      "protocol": "vless",
	      "settings": {
	        "clients": [
	          { "id": "${UUID}", "email": "admin@example.com", "flow": "xtls-rprx-vision" }${guests}
	        ],
	        "decryption": "none"
	      },
	      "streamSettings": {
	        "network": "tcp",
	        "security": "reality",
	        "realitySettings": {
	          "show": false,
	          "dest": "${DEST}",
	          "xver": 0,
	          "serverNames": ["","${SNI}"],
	          "privateKey": "${private_key}",
	          "shortIds": [""]
	        }
	      }
	    },
	    {
	      "listen": "127.0.0.1",
	      "port": 10085,
	      "protocol": "dokodemo-door",
	      "settings": {
	        "address": "127.0.0.1"
	      },
	      "tag": "api-in"
	    }
	  ],
	  "outbounds": [
	    ${SOCKS5_OUTBOUND}
        {
            "protocol": "freedom",
            "settings": {"domainStrategy": "UseIPv4v6"},
            "tag": "direct"
        }
      ],
	  "routing": {
	    "domainStrategy": "AsIs",
	    "rules": [
	      { "type": "field", "inboundTag": ["api-in"], "outboundTag": "api" }
	    ]
	  }
	}
EOF

systemctl enable xray
systemctl restart xray

# 防火墙处理 (Rocky/AlmaLinux 默认启用 firewalld)
if [[ "$OS_FAMILY" == "rhel" ]] && systemctl is-active --quiet firewalld 2>/dev/null; then
	firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
	firewall-cmd --permanent --add-port=${PORT}/tcp >/dev/null 2>&1
	firewall-cmd --reload >/dev/null 2>&1
	warning003="firewalld 已放行 80/tcp ${PORT}/tcp"
fi

# Network optimize
touch /etc/sysctl.conf

# 检查是否已包含指定的起始关键字
if ! grep -q "^### proxy optimization start ###$" /etc/sysctl.conf; then
    tee -a /etc/sysctl.conf >/dev/null <<EOF

### proxy optimization start ###
vm.swappiness=10
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = ${QDISC}
net.core.netdev_max_backlog = 8192
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 8192 262144 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
### proxy optimization end ###
EOF
    sysctl -p
	warning004="初次安装完成，考虑使用 reboot 重启机器以优化网络参数"
fi

# 调试信息
systemctl status xray --no-pager -l
systemctl status caddy --no-pager -l

# 获取代理位置
COUNTRYCODE=$(echo "$TRACE4" | grep '^loc=' | cut -d= -f2)
COLO=$(echo "$TRACE4" | grep '^colo=' | cut -d= -f2)
# 获取 ASN
if [[ -n "$IPV4" ]] && command -v dig >/dev/null 2>&1; then
    ASN_NUM=$(dig +short "$(echo "$IPV4"|awk -F. '{print $4"."$3"."$2"."$1}').origin.asn.cymru.com" TXT 2>/dev/null|cut -d\| -f1|tr -dc 0-9)
fi
[[ -z "$ASN_NUM" ]] && ASN_NUM=$(curl -s --max-time 3 https://ipwho.is/ 2>/dev/null|grep -oP '"asn":\s*"?\K[0-9]+'|sed 's/"//g')

# 拼接并生成地域 ID (格式如 US01)
REGION_ID=$(printf "%s%02d" "${COUNTRYCODE:-XX}" "$(echo -n "${ASN_NUM}${COLO:-XX}"|cksum|awk '{print $1%100}')")

# 生成 VLESS Reality URL
insert="SEED=$SEED"
# 如果AUTOTLS包含关键词shortlived
if [[ "$AUTOTLS" == *"shortlived"* ]]; then
	insert+=" SNI=rawip"
else
	insert+=" SNI=$SNI"
fi
[[ $PORT -ne 443 ]] && insert+=" PORT=$PORT"
[[ -n "$SOCKS5" ]] && insert+=" SOCKS5=$SOCKS5"
if [[ -z "$HOST" ]]; then
	HOST=$IPV4
else
	insert+=" HOST=$HOST"
fi

vless_reality_url="vless://${UUID}@${HOST}:${PORT}?flow=xtls-rprx-vision&type=tcp&security=reality&fp=firefox&sni=${SNI}&pbk=${public_key}#${REGION_ID}"

qrencode -t UTF8 -s 1 -l L -m 2 "$vless_reality_url" >~/_xray_url_
echo "---------- VLESS Reality URL ----------" >>~/_xray_url_
echo $vless_reality_url >>~/_xray_url_
echo >>~/_xray_url_
echo "以上节点信息保存在 ~/_xray_url_ 文件中, 以后使用 cat _xray_url_ 查看" >>~/_xray_url_
#对于Guest用户，输出一对一的url信息
if [[ -n "$guests" ]]; then
	echo "" >>~/_xray_url_
	echo "Guest 用户信息 ----------" >>~/_xray_url_
	echo "空间有限不生成二维码，可用前端工具自行生成 https://emn178.github.io/online-tools/qr-code/generator/ " >>~/_xray_url_
	for arg in "${args[@]}"; do
		if [[ "$arg" == "@keep-caddyfile" ]]; then
			continue
		fi
		guest_uuid=$(xray uuid -i "${arg}${USERSEC}")
		guest_url="vless://${guest_uuid}@${HOST}:${PORT}?flow=xtls-rprx-vision&type=tcp&security=reality&fp=firefox&sni=${SNI}&pbk=${public_key}#${REGION_ID}-${arg}"
		echo "${guest_url}" >>~/_xray_url_
	done

	echo "查询自重启至今的统计流量：（字节）" >>~/_xray_url_
	echo "xray api statsquery --server=127.0.0.1:10085" >>~/_xray_url_
fi

echo "" >>~/_xray_url_
echo "妥善保存 备用信息 $(TZ=Asia/Shanghai date "+%Y-%m-%d %H:%M %Z") ${REGION_ID}" >>~/_xray_url_
echo "重装命令：" >>~/_xray_url_
echo -n "$insert bash <(curl -fsSL ${BASEURL}install.sh) " >>~/_xray_url_
if [[ ${#args[@]} -gt 0 ]]; then
	echo -n "${args[*]}" >>~/_xray_url_
fi
echo "" >>~/_xray_url_
echo "------------------------------------" >>~/_xray_url_
echo $warning000 >>~/_xray_url_
echo $warning001 >>~/_xray_url_
echo $warning002 >>~/_xray_url_

cat ~/_xray_url_
if [[ $CADDYFILE -eq 0 ]]; then
	echo ""
	echo "===== 由于 @keep-caddyfile 标签，没有更新Caddyfile ======"
fi

echo "VPS IPv4:    $IPV4"
echo "VPS IPv6:    [$IPV6]"
echo $warning004
echo $warning003
