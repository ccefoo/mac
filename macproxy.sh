#!/bin/bash

# ==============================================================================
# macOS Wi-Fi 全局代理控制脚本（支持 -wifi 参数，自动切换）
# ==============================================================================

# 配置变量
WORK_DIR="$HOME/clash"
CLASH_PATH="$WORK_DIR/clash"
CONFIG_PATH="$WORK_DIR/config.yaml"


PROXY_TYPE="HTTP"           # HTTP 或 SOCKS5
PROXY_HOST="127.0.0.1"
HTTP_PROXY_PORT="7890"
SOCKS5_PROXY_PORT="7891"

IGNORE_HOSTS=(
    "localhost"
    "127.0.0.1"
    "*.lan"
    "*.local"
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "*.eastmoney.com"
    "*.18.cn"
)

# ==============================================================================
# 参数解析
# ==============================================================================
WIFI_INTERFACE="Wi-Fi"   # 默认值
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -wifi)
            WIFI_INTERFACE="$2"
            shift 2
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL_ARGS[@]}"  # 还原位置参数

ACTION="$1"

# ==============================================================================
# 函数定义
# ==============================================================================

# 列出所有 Wi-Fi 接口
list_wifi_interfaces() {
    echo "Available Wi-Fi services:"
    networksetup -listallnetworkservices | grep "^Wi-Fi" || echo "  (No Wi-Fi service found)"
}

# 验证 Wi-Fi 接口是否存在；若不存在，则自动选择第一个可用的
validate_wifi_interface() {
    if networksetup -listallnetworkservices | grep -qx "$WIFI_INTERFACE"; then
        return 0
    fi

    echo "Warning: Wi-Fi service '$WIFI_INTERFACE' not found."

    local first_wifi
    first_wifi=$(networksetup -listallnetworkservices | grep "^Wi-Fi" | head -n1)

    if [[ -n "$first_wifi" ]]; then
        WIFI_INTERFACE="$first_wifi"
        echo "→ Auto-switching to available Wi-Fi service: '$WIFI_INTERFACE'"
    else
        echo "Error: No Wi-Fi service available."
        exit 1
    fi
}

# 检查 Clash 是否运行
check_clash_running() {
    if pgrep -x "clash" > /dev/null; then return 0; else return 1; fi
}

# 检查代理状态
check_proxy_status() {
    local interface="$1"
    local http_status socks_status
    http_status=$(networksetup -getwebproxy "$interface" | grep "Enabled: Yes" || echo "")
    socks_status=$(networksetup -getsocksfirewallproxy "$interface" | grep "Enabled: Yes" || echo "")

    if [[ -n "$http_status" && "$PROXY_TYPE" == "HTTP" ]]; then
        echo "HTTP Proxy is enabled on '$interface' (Server: $PROXY_HOST, Port: $HTTP_PROXY_PORT)"
    elif [[ -n "$socks_status" && "$PROXY_TYPE" == "SOCKS5" ]]; then
        echo "SOCKS5 Proxy is enabled on '$interface' (Server: $PROXY_HOST, Port: $SOCKS5_PROXY_PORT)"
    else
        echo "Proxy is disabled on '$interface'"
    fi
}

# 状态检查（含真实IP和代理IP）
check_proxy_functional() {
    if ! command -v jq &> /dev/null; then
        echo "Warning: 'jq' not found, location info unavailable. Run: brew install jq" >&2
        return 1
    fi
    local proxy_url
    if [[ "$PROXY_TYPE" == "HTTP" ]]; then
        proxy_url="http://${PROXY_HOST}:${HTTP_PROXY_PORT}"
    else
        proxy_url="socks5://${PROXY_HOST}:${SOCKS5_PROXY_PORT}"
    fi
    local test_urls=("http://ip-api.com/json" "http://ipinfo.io")
    local direct_response_json="" successful_direct_url=""
    for url in "${test_urls[@]}"; do
        direct_response_json=$(curl -s -m 8 "$url")
        [[ -n "$direct_response_json" ]] && successful_direct_url="$url" && break
    done
    local proxied_response_json="" successful_proxy_url=""
    for url in "${test_urls[@]}"; do
        proxied_response_json=$(curl -s -m 8 --proxy "$proxy_url" "$url")
        [[ -n "$proxied_response_json" ]] && successful_proxy_url="$url" && break
    done

    parse_location() {
        local response_json="$1" url="$2"
        local ip city region country
        if [[ "$url" == *"ip-api.com"* ]]; then
            ip=$(echo "$response_json" | jq -r '.query')
            city=$(echo "$response_json" | jq -r '.city')
            region=$(echo "$response_json" | jq -r '.regionName')
            country=$(echo "$response_json" | jq -r '.country')
        else
            ip=$(echo "$response_json" | jq -r '.ip')
            city=$(echo "$response_json" | jq -r '.city')
            region=$(echo "$response_json" | jq -r '.region')
            country=$(echo "$response_json" | jq -r '.country')
        fi
        local parts=()
        [[ -n "$city" && "$city" != "null" ]] && parts+=("$city")
        [[ -n "$region" && "$region" != "null" ]] && parts+=("$region")
        [[ -n "$country" && "$country" != "null" ]] && parts+=("$country")
        echo "$ip | $(IFS=', '; echo "${parts[*]}")"
    }
    local direct_info=$(parse_location "$direct_response_json" "$successful_direct_url")
    local proxied_info=$(parse_location "$proxied_response_json" "$successful_proxy_url")

    local direct_ip=$(echo "$direct_info" | cut -d'|' -f1 | xargs)
    local direct_loc=$(echo "$direct_info" | cut -d'|' -f2 | xargs)
    local proxy_ip=$(echo "$proxied_info" | cut -d'|' -f1 | xargs)
    local proxy_loc=$(echo "$proxied_info" | cut -d'|' -f2 | xargs)

    echo "  Real IP: $direct_ip ($direct_loc)"
    if [[ -z "$proxy_ip" || "$proxy_ip" == "null" ]]; then
        echo " Proxy IP: Test failed"
        return 1
    fi
    echo " Proxy IP: $proxy_ip ($proxy_loc)"
    if [[ "$proxy_ip" != "$direct_ip" ]]; then
        echo "   Status: Proxy is functional"
        return 0
    else
        echo "   Status: Proxy NOT functional"
        return 1
    fi
}

# 启用代理
enable_proxy() {
    validate_wifi_interface

    if [[ ! -f "$CLASH_PATH" ]]; then echo "Error: Clash not found" >&2; exit 1; fi
    if [[ ! -f "$CONFIG_PATH" ]]; then echo "Error: Clash config missing" >&2; exit 1; fi
    if [[ ! -d "$WORK_DIR" ]]; then echo "Error: Work dir missing" >&2; exit 1; fi

    if ! check_clash_running; then
        echo "Starting Clash..."
        (cd "$WORK_DIR" && "$CLASH_PATH" -f "$CONFIG_PATH" > /tmp/clash.log 2>&1 &)
        sleep 2
    fi

    if [[ "$PROXY_TYPE" == "HTTP" ]]; then
        networksetup -setwebproxy "$WIFI_INTERFACE" "$PROXY_HOST" "$HTTP_PROXY_PORT"
        networksetup -setsecurewebproxy "$WIFI_INTERFACE" "$PROXY_HOST" "$HTTP_PROXY_PORT"
        networksetup -setsocksfirewallproxy "$WIFI_INTERFACE" "" ""
    else
        networksetup -setsocksfirewallproxy "$WIFI_INTERFACE" "$PROXY_HOST" "$SOCKS5_PROXY_PORT"
        networksetup -setwebproxy "$WIFI_INTERFACE" "" ""
        networksetup -setsecurewebproxy "$WIFI_INTERFACE" "" ""
    fi
    networksetup -setproxybypassdomains "$WIFI_INTERFACE" "${IGNORE_HOSTS[@]}"
    echo "Proxy enabled on '$WIFI_INTERFACE'"
}

# 停用代理
disable_proxy() {
    validate_wifi_interface

    networksetup -setwebproxystate "$WIFI_INTERFACE" off
    networksetup -setsecurewebproxystate "$WIFI_INTERFACE" off
    networksetup -setsocksfirewallproxystate "$WIFI_INTERFACE" off
    networksetup -setproxybypassdomains "$WIFI_INTERFACE" ""
    echo "Proxy disabled on '$WIFI_INTERFACE'"

    if check_clash_running; then
        pkill -x clash
        sleep 1
        echo "Clash stopped"
    fi
}

# 显示状态
show_status() {
    validate_wifi_interface

    echo "=== Proxy Status ==="
    if check_clash_running; then
        echo "Clash is running (PID: $(pgrep -x clash))"
    else
        echo "Clash is not running"
    fi

    check_proxy_status "$WIFI_INTERFACE"

    echo "--- IP & Connectivity ---"
    if check_clash_running; then
        check_proxy_functional
    else
        local r=$(curl -s -m 8 "http://ip-api.com/json")
        local ip=$(echo "$r" | jq -r '.query')
        local city=$(echo "$r" | jq -r '.city')
        local region=$(echo "$r" | jq -r '.regionName')
        local country=$(echo "$r" | jq -r '.country')
        echo "  Real IP: $ip ($city, $region, $country)"
        echo "   Status: Proxy off"
    fi
}

# ==============================================================================
# 主逻辑
# ==============================================================================
case "$ACTION" in
    on) enable_proxy ;;
    off) disable_proxy ;;
    info) show_status ;;
    list) list_wifi_interfaces ;;
    *) echo "Usage: $0 [-wifi <service>] {on|off|info|list}" >&2; exit 1 ;;
esac
