# proxy setup
HTTP_PROXY_SRV=10.20.0.1:1081
SOCK_PROXY_SRV=10.20.0.1:1080

alias proxyon="export http_proxy=http://${HTTP_PROXY_SRV};
    export https_proxy=http://${HTTP_PROXY_SRV};
    export ALL_PROXY=http://${HTTP_PROXY_SRV};
    export HTTP_PROXY=http://${HTTP_PROXY_SRV};
    export HTTPS_PROXY=http://${HTTP_PROXY_SRV}"
alias proxyoff="unset http_proxy;
    unset https_proxy;
    unset HTTP_PROXY;
    unset HTTPS_PROXY;
    unset ALL_PROXY"

export NO_PROXY=localhost,127.0.0.1,::1
export no_proxy=localhost,127.0.0.1,::1

# qrencode
alias qrc="qrencode -o - -t UTF8"


# systemd log
alias run='systemctl list-units  --type=service  --state=running'
alias miss='systemctl list-units  --type=service  --state=failed'
alias bootlog='journalctl --list-boots'

# history
export HISTTIMEFORMAT='%F %T '
export HISTSIZE=3000
export HISTFILESIZE=3000
export TZ=Asia/Shanghai

# PS1 setting
os_name_001=`uname`

case $os_name_001 in

"Linux")
    # Green
    export PS1='\[\e[92m\]\u@\h:\[\e[94m\]\w\[\e[93m\]\$ \[\e[0m\]'
    export PATH=$PATH:/sbin:$HOME/bin:/sbin:/usr/sbin:/usr/local/sbin
    # export PS1="\[\033[01;32m\]\u\[\033[01;33m\]@\[\033[01;32m\]\h \[\033[01;34m\]\W\[\033[00m\]\\$"
    ;;
"FreeBSD")
    # Red
    export PS1='\[\e[31m\]\u@\h:\[\e[94m\]\w\[\e[93m\]\$ \[\e[0m\]'
    ;;
"OpenBSD"|"NetBSD")
    export PS1="\[\e[90m\]\u\[\e[38;5;214m\]@\[\e[93m\]\h\[\e[38;5;214m\]:\[\e[38;5;71m\]\w\[\e[38;5;214m\]$ \[\e[00m\]"
    ;;
*)
    # Yellow
    export PS1='\[\e[93m\]\u@\h:\[\e[94m\]\w\[\e[93m\]\$ \[\e[0m\]'
;;
esac