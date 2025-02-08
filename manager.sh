#!/bin/bash
listen_ip="127.0.0.1"
start_listen_port=50000

# 下面的变量不用更改
readonly base_dir="$HOME/.ss-manager"
readonly config_dir=${base_dir}/config.d
readonly pid_dir="${base_dir}/pid"
readonly log_dir="${base_dir}/log"
readonly index_file="${base_dir}/index.json"
data_array=()
function get_sub_address(){
    sub_address=${SS_MANAGER_SUB_ADDRESS}
    test -z "$sub_address" && {
        echo "请定义SS_MANAGER_SUB_ADDRESS变量，此变量表示订阅地址,格式前缀http"
        exit 1
    }
}
function get_config() {
    echo "当前订阅地址为: ${sub_address}"
    local seq
    seq=0
    content=$(cat "${index_file}")
    length=$(echo "$content" | jq 'length')
    for ((seq; seq < length; seq = seq + 1)); do
        line=$(echo "$content" | jq ".[${seq}]")
        local_listen=$(echo "$line" | jq -r ".local_listen")
        name=$(echo "$line" | jq -r ".name")
        file=$(echo "$line" | jq -r ".file")
        echo "${seq} ${name}"
    done
}
function get_verbose_config() {
    echo "当前订阅地址为: ${sub_address}"
    local seq
    seq=0
    content=$(cat "${index_file}")
    length=$(echo "$content" | jq 'length')
    for ((seq; seq < length; seq = seq + 1)); do
        line=$(echo "$content" | jq ".[${seq}]")
        local_listen=$(echo "$line" | jq -r ".local_listen")
        name=$(echo "$line" | jq -r ".name")
        file=$(echo "$line" | jq -r ".file")
        echo "${seq} 名称: ${name}  本地代理监听: ${local_listen}  文件名: ${file}"
    done
}
function create_config() {
    base64_list=$(curl -s "${sub_address}" | base64 -d)
    seq=0
    while IFS= read -r line; do # Use IFS= to avoid trimming leading/trailing whitespace
        local index_json
        if [[ ! $line =~ ^ss:// ]]; then
            echo "Subscription address type is not ss://" >&2 # Redirect error to stderr
            exit 1
        fi

        line=${line#*//} # Remove ss:// prefix

        # Extract data using parameter expansion and command substitution
        method=$(echo "$line" | cut -d@ -f1 | base64 -d | cut -d: -f1)
        password=$(echo "$line" | cut -d@ -f1 | base64 -d | cut -d: -f2)
        server=$(echo "$line" | cut -d@ -f2 | cut -d# -f1 | cut -d: -f1)
        server_port=$(echo "$line" | cut -d# -f1 | cut -d: -f2)
        name=$(python3 -c "import sys, urllib.parse; print(urllib.parse.unquote(sys.argv[1]))" "${line#*#}") # Unquote the name

        start_listen_port=$(get_local_port)
        config_json="{\"server\":\"$server\",\"server_port\":$server_port,\"password\":\"$password\",\"method\":\"$method\",\"local_port\":$start_listen_port}"

        uuid=$(head -1 /dev/urandom | od -x | awk '{print $2$3"-"$4$5"-"$6$7"-"$8$9}' | head -n1)

        # 生成连接信息到配置文件夹
        config_uuid_file="${config_dir}/${uuid}.json"
        echo "$config_json" | jq >"${config_uuid_file}"

        # 将连接信息放到索引文件中，用于参考
        name=$(echo "${name}" | tr -d "\r")
        local_listen="socks5h://${listen_ip}:${start_listen_port}"
        index_json=$(jq -n --arg a "${local_listen}" --arg b "$name" --arg c "${config_uuid_file}" '{name: $b, local_listen: $a, file: $c}')
        data_array+=("${index_json}")
        seq=$((seq+1))
        echo "${seq} ${name}"

    done <<<"$base64_list" # Use a here-string for better variable expansion

    echo "${data_array[*]}" | jq -s . >"${index_file}"

}
function rm_config() {

    rm -rf "${config_dir}" && echo "已删除${config_dir}"
    rm -f "${index_file}" && echo "已删除${index_file}"
    mkdir -p "${config_dir}" >/dev/null 2>&1 || {
        echo "创建文件夹失败,路径:${config_dir}"
        exit 1
    }
}
function get_local_port() {

    while nmap -sT -p ${start_listen_port} 127.0.0.1 | grep "^${start_listen_port}/tcp\ open" >/dev/null 2>&1; do
        start_listen_port=$((start_listen_port + 1))
    done
    echo $((start_listen_port + 1))
}
function check_ss() {
    local seq
    seq=0
    local ret
    ret=$(find ${pid_dir} -type f -name "*.pid")
    test -z "$ret" && {
        echo "未发现服务监听"
        return
    }
    while IFS= read -r pid_file; do
        local file
        local json_content

        pid=$(cat "$pid_file")
        if ! ps -p "$pid" >/dev/null 2>&1; then
            rm -f "$pid_file"
            continue
        fi

        args=$(ps -p "$(cat "$pid_file")" -o args | tail -n1)
        file="$(echo "$args" | awk '{print $3}')"

        json_content=$(jq '.[] | select(.file == "'"${file}"'")' <${index_file})
        local_listen=$(echo "$json_content" | jq -r ".local_listen")
        name=$(echo "$json_content" | jq -r ".name")
        echo "序号: $((seq + 1))"
        echo "PID: $(cat "$pid_file")"
        echo "启动参数: ${args}"
        echo "名称: ${name}"
        echo "本地代理地址：${local_listen}"
        echo "export http_proxy=${local_listen}"
        echo "-"
    done <<<"${ret}"
}
function start_ss() {

    content=$(cat "${index_file}")
    length=$(echo "$content" | jq 'length')

    echo "输入序号（通过查看配置可确定）"
    read -r seq
    length=$(echo "$content" | jq 'length')
    seq=$((seq - 1))
    local pid
    line=$(echo "$content" | jq ".[${seq}]")
    local_listen=$(echo "$line" | jq -r ".local_listen")
    port=$(echo "$local_listen" | awk -F ":" '{print $3}')
    name=$(echo "$line" | jq -r ".name")
    file=$(echo "$line" | jq -r ".file")
    pid_file="${pid_dir}/${port}.pid"
    log_file="${log_dir}/${port}.log"
    test -r "${pid_file}" && {
        echo "发现已存在对应的pid文件"
        pid=$(cat "$pid_file")
        if ps -p "$pid" >/dev/null 2>&1; then
            kill "${pid}" && rm -f "$pid_file" && echo "已停止 ${pid}"
        else
            rm -f "$pid_file" && echo "删除无效的pid文件"
        fi
    }
    echo "启动"
    echo "名称: ${name} "
    echo "本地代理地址: ${local_listen}"
    echo "配置文件: ${file}"
    echo "日志文件位置: ${log_file}"
    echo "PID文件位置: ${pid_file}"
    echo "启动命令: ss-local -c "${file}" -f "${pid_file}" --fast-open"

    nohup ss-local -c "${file}" -f "${pid_file}" --fast-open >"$log_file" 2>&1 &

    # 通过pid文件来判断程序是否启动正常
    sleep 1
    if [ -n "$(cat "${pid_file}")" ]; then
        echo "PID: $(cat "${pid_file}")"
    else
        echo -e "\n启动失败"
    fi
}
function stop_ss() {
    local seq
    local pid_file
    local pid
    echo "输入序号（通过查看服务监听可确定）"
    read -r seq
    pid_file=$(find ${pid_dir} -type f -name "*.pid" | awk "FNR==${seq}")

    pid=$(cat "$pid_file")
    if ps -p "$pid" >/dev/null 2>&1; then
        kill "${pid}" && rm -f "$pid_file" && echo "已停止 ${pid}"
    else
        rm -f "$pid_file"
    fi
}
function stop_all_ss() {
    local pid_file_lsit
    pid_file_lsit=$(find ${pid_dir} -type f -name "*.pid")
    test -z "$pid_file_lsit" && {
        echo "未发现服务监听"
        return
    }
    while IFS= read -r line; do
        pid=$(cat "$line")
        if ps -p "pid" >/dev/null 2>&1; then
            kill "${pid}" && rm -f "$line" && echo "已停止 ${pid}"
        else
            rm -f "$line"
        fi
    done <<<"${pid_file_lsit}"
    echo "已停止所有"

}
function check_commmand() {
    which ss-local >/dev/null 2>&1 || {
        echo "未找到ss-local命令，项目地址：https://github.com/shadowsocksr-backup/shadowsocksr-libev"
    }
    which nmap >/dev/null 2>&1 || {
        echo "未找到nmap命令"
    }
    which jq >/dev/null 2>&1 || {
        echo "未找到jq命令"
    }
    which curl >/dev/null 2>&1 || {
        echo "未找到curl命令"
    }
}
function check_dir() {
    test ! -e ${config_dir} && {
        mkdir -p ${config_dir}
    }
    test ! -e ${pid_dir} && {
        mkdir -p ${pid_dir}
    }
    test ! -e ${log_dir} && {
        mkdir -p ${log_dir}
    }
}

function main() {
    check_commmand
    check_dir
    while true; do

        echo ""
        echo "-----------------------"
        echo -e "1\t订阅\t获取配置"
        echo -e "2\t订阅\t查看配置"
        echo -e "3\t订阅\t查看详细配置"
        echo -e "4\t订阅\t删除配置且停止所有服务"
        echo -e "5\t服务监听\t查看"
        echo -e "6\t服务监听\t启动"
        echo -e "7\t服务监听\t停止"
        echo -e "8\t服务监听\t停止所有"
        echo -e "其他键\t退出"

        echo ""
        read -r seq
        echo ""
        case "${seq}" in
        1)
            get_sub_address
            create_config
            ;;
                2)
            get_config
            ;;
        3)
            get_verbose_config
            ;;
        4)
            stop_all_ss
            rm_config
            ;;
        5)
            check_ss
            ;;
        6)
            start_ss
            ;;
        7)
            stop_ss
            ;;
        8)
            stop_all_ss
            ;;
        *)
            exit 0
            ;;
        esac

    done
}
main
