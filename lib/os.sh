#!/usr/bin/env bash
# lib/os.sh — detecção de distro/capacidades, sem allowlist fechada. O core não tem distro
# preferida: is_rhel_like/is_debian_like/is_suse_like são cidadãos de primeira classe. Quem
# decide se um host é compatível é o MÓDULO (via `os.families` no module.json), não esta lib.

OS_ID=unknown
OS_ID_LIKE=''
OS_NAME=''
OS_PRETTY=''
OS_VERSION=''
OS_VERSION_ID=''
OS_VERSION_MAJOR=''
OS_VERSION_MINOR=''
OS_FAMILY=unknown
OS_ARCH=''
OS_KERNEL=''
_OS_INITIALIZED=0
declare -gA _OSR=()

os::_parse_os_release() {
  local file=$1 k v
  while IFS='=' read -r k v; do
    [[ $k =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    v=${v%\"}
    v=${v#\"}
    v=${v%\'}
    v=${v#\'}
    _OSR[$k]=$v
  done <"$file"
  return 0
}

os::_parse_redhat_release() {
  local content=''
  read -r content </etc/redhat-release || true
  OS_PRETTY=$content
  case $content in
    *CentOS*) OS_ID=centos ;;
    *"Red Hat"*) OS_ID=rhel ;;
    *Fedora*) OS_ID=fedora ;;
    *AlmaLinux*) OS_ID=almalinux ;;
    *Rocky*) OS_ID=rocky ;;
    *) OS_ID=linux ;;
  esac
  if [[ $content =~ ([0-9]+\.[0-9]+) ]]; then
    OS_VERSION_ID=${BASH_REMATCH[1]}
  elif [[ $content =~ ([0-9]+) ]]; then
    OS_VERSION_ID=${BASH_REMATCH[1]}
  fi
  return 0
}

os::_derive_family() {
  OS_FAMILY=unknown
  if os::like rhel || os::like fedora || [[ -e /etc/redhat-release ]] ||
    { command -v rpm >/dev/null 2>&1 && [[ -d /etc/yum.repos.d ]]; }; then
    OS_FAMILY=rhel
  elif os::like debian || [[ -e /etc/debian_version ]] || command -v dpkg >/dev/null 2>&1; then
    OS_FAMILY=debian
  elif os::like suse || [[ -e /etc/SuSE-release ]] || command -v zypper >/dev/null 2>&1; then
    OS_FAMILY=suse
  fi
  return 0
}

# Nunca faz `source` em /etc/os-release (seria RCE como root se o arquivo fosse gravável por
# outro usuário) — parseia linha a linha.
os::init() {
  _OSR=()
  OS_ID=unknown
  if [[ -r /etc/os-release ]]; then
    os::_parse_os_release /etc/os-release
  elif [[ -r /etc/redhat-release ]]; then
    os::_parse_redhat_release
  elif [[ -r /etc/debian_version ]]; then
    OS_ID=debian
    read -r OS_VERSION_ID </etc/debian_version || true
  fi
  OS_ID=${_OSR[ID]:-$OS_ID}
  OS_ID=${OS_ID,,}
  OS_ID_LIKE=${_OSR[ID_LIKE]:-}
  OS_ID_LIKE=${OS_ID_LIKE,,}
  OS_NAME=${_OSR[NAME]:-$OS_ID}
  OS_PRETTY=${_OSR[PRETTY_NAME]:-${OS_PRETTY:-$OS_NAME}}
  OS_VERSION=${_OSR[VERSION]:-}
  OS_VERSION_ID=${_OSR[VERSION_ID]:-$OS_VERSION_ID}
  OS_VERSION_MAJOR=${OS_VERSION_ID%%.*}
  if [[ $OS_VERSION_ID == *.* ]]; then
    OS_VERSION_MINOR=${OS_VERSION_ID#*.}
    OS_VERSION_MINOR=${OS_VERSION_MINOR%%.*}
  else
    OS_VERSION_MINOR=''
  fi
  OS_ARCH=$(uname -m)
  OS_KERNEL=$(uname -r)
  # Marcar como inicializado ANTES de chamar _derive_family é essencial: _derive_family chama
  # os::like, que chama os::_ensure — se a flag só fosse setada depois, isso reentraria em
  # os::init recursivamente (o campo OS_ID já está populado neste ponto, então é seguro).
  _OS_INITIALIZED=1
  os::_derive_family
  return 0
}

os::_ensure() {
  (( _OS_INITIALIZED )) && return 0
  os::init
}

# --- getters (lazy self-init) ------------------------------------------------------------------
os::id() {
  os::_ensure
  printf '%s' "$OS_ID"
}
os::version() {
  os::_ensure
  printf '%s' "$OS_VERSION_ID"
}
os::version_major() {
  os::_ensure
  printf '%s' "$OS_VERSION_MAJOR"
}
os::family() {
  os::_ensure
  printf '%s' "$OS_FAMILY"
}
os::pretty() {
  os::_ensure
  printf '%s' "$OS_PRETTY"
}
os::arch() {
  os::_ensure
  printf '%s' "$OS_ARCH"
}

os::like() {
  os::_ensure
  local token=$1
  [[ " $OS_ID $OS_ID_LIKE " == *" $token "* ]]
}

os::is_rhel_like() {
  os::_ensure
  [[ $OS_FAMILY == rhel ]]
}
os::is_debian_like() {
  os::_ensure
  [[ $OS_FAMILY == debian ]]
}
os::is_suse_like() {
  os::_ensure
  [[ $OS_FAMILY == suse ]]
}

# --- capacidades (nunca por identidade de distro) -----------------------------------------------
os::pkg_manager() {
  local mgr
  for mgr in dnf yum microdnf apt-get zypper apk; do
    if command -v "$mgr" >/dev/null 2>&1; then
      printf '%s' "$mgr"
      return 0
    fi
  done
  return 1
}

os::pkg_install() {
  local mgr
  mgr=$(os::pkg_manager) || {
    log::error 'nenhum gerenciador de pacotes conhecido encontrado'
    return 1
  }
  case $mgr in
    dnf | yum | microdnf) run -- "$mgr" install -y "$@" ;;
    apt-get) run -- apt-get install -y "$@" ;;
    zypper) run -- zypper install -y "$@" ;;
    apk) run -- apk add "$@" ;;
  esac
}

os::has_systemd() { [[ -d /run/systemd/system ]]; }

os::service_manager() {
  if os::has_systemd; then
    printf 'systemd'
    return 0
  fi
  if [[ -d /etc/init.d ]]; then
    printf 'sysvinit'
    return 0
  fi
  return 1
}

os::service_active() {
  local name=$1
  if os::has_systemd; then
    systemctl is-active --quiet "$name" 2>/dev/null
    return $?
  fi
  if command -v service >/dev/null 2>&1; then
    service "$name" status >/dev/null 2>&1
    return $?
  fi
  return 1
}

os::is_container() {
  [[ -e /.dockerenv ]] && return 0
  [[ -e /run/.containerenv ]] && return 0
  if [[ -r /proc/1/cgroup ]] && grep -qE '(docker|kubepods|containerd|lxc)' /proc/1/cgroup 2>/dev/null; then
    return 0
  fi
  return 1
}

os::is_root() { (( EUID == 0 )); }

os::require_root() {
  local reason=${1:-esta operação}
  os::is_root && return 0
  log::error '%s requer privilégios de root (rodando como uid %d)' "$reason" "$EUID"
  log::hint 'tente: sudo %s' "${0##*/}"
  exit "$PVX_EXIT_NOPERM"
}

# Guarda SOFT: avisa e continua por padrão. Só bloqueia (retorna código de erro, não `exit`)
# se PVX_ALLOW_UNSUPPORTED_OS não estiver setado — quem chama decide o que fazer com o retorno.
os::require_rhel_like() {
  os::_ensure
  local reason=${1:-esta ferramenta}
  os::is_rhel_like && return 0
  if [[ ${PVX_ALLOW_UNSUPPORTED_OS:-0} == 1 ]]; then
    log::warn '%s tem como alvo sistemas RHEL-like; detectado %s (%s) — continuando porque PVX_ALLOW_UNSUPPORTED_OS=1' \
      "$reason" "$OS_ID" "$OS_PRETTY"
    return 0
  fi
  log::error '%s tem como alvo sistemas RHEL-like; detectado %s (%s)' "$reason" "$OS_ID" "$OS_PRETTY"
  log::hint 'defina PVX_ALLOW_UNSUPPORTED_OS=1 se souber o que está fazendo'
  return "$PVX_EXIT_UNSUPPORTED"
}

os::require_debian_like() {
  os::_ensure
  local reason=${1:-esta ferramenta}
  os::is_debian_like && return 0
  if [[ ${PVX_ALLOW_UNSUPPORTED_OS:-0} == 1 ]]; then
    log::warn '%s tem como alvo sistemas Debian-like; detectado %s (%s) — continuando porque PVX_ALLOW_UNSUPPORTED_OS=1' \
      "$reason" "$OS_ID" "$OS_PRETTY"
    return 0
  fi
  log::error '%s tem como alvo sistemas Debian-like; detectado %s (%s)' "$reason" "$OS_ID" "$OS_PRETTY"
  log::hint 'defina PVX_ALLOW_UNSUPPORTED_OS=1 se souber o que está fazendo'
  return "$PVX_EXIT_UNSUPPORTED"
}

os::require_min_version() {
  os::_ensure
  local major=$1 reason=${2:-esta ferramenta}
  if [[ -z $OS_VERSION_MAJOR ]]; then
    log::warn 'não foi possível determinar a versão do SO; pulando checagem de versão mínima'
    return 0
  fi
  if (( OS_VERSION_MAJOR >= major )); then
    return 0
  fi
  log::error '%s requer %s versão >= %s (detectado %s)' "$reason" "$OS_ID" "$major" "$OS_VERSION_MAJOR"
  return "$PVX_EXIT_UNSUPPORTED"
}

os::selinux_state() {
  if command -v getenforce >/dev/null 2>&1; then
    getenforce 2>/dev/null | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  if [[ -r /sys/fs/selinux/enforce ]]; then
    local v=''
    read -r v </sys/fs/selinux/enforce || true
    if [[ $v == 1 ]]; then printf 'enforcing'; else printf 'permissive'; fi
    return 0
  fi
  printf 'disabled'
  return 0
}

os::mysql_flavor() {
  if command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
    local out=''
    out=$(mariadb --version 2>/dev/null) || out=$(mysql --version 2>/dev/null) || true
    case $out in
      *MariaDB*) printf 'mariadb' ;;
      *Percona*) printf 'percona' ;;
      *) printf 'mysql' ;;
    esac
    return 0
  fi
  printf 'none'
  return 0
}

os::issabel_version() {
  if [[ -r /etc/issabel.conf ]]; then
    grep -m1 -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' /etc/issabel.conf 2>/dev/null || true
    return 0
  fi
  if command -v rpm >/dev/null 2>&1; then
    rpm -q --qf '%{VERSION}\n' issabel-pbx 2>/dev/null || true
    return 0
  fi
  return 1
}

os::asterisk_version() {
  if command -v asterisk >/dev/null 2>&1; then
    asterisk -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true
    return 0
  fi
  return 1
}
