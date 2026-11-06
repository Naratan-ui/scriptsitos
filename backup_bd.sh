#!/bin/bash
# ==========================================================
# BACKUP DE LA BASE DE DATOS CON BINARY LOGS
# Corre en la VM de BASE DE DATOS, como root (cron o a mano).
# ==========================================================
# Estrategia:
#   COMPLETO     el día 1 de cada mes: mysqldump que guarda en qué
#                binary log y posición quedó (--source-data=2)
#   DIFERENCIAL  los domingos: todos los binary logs desde el completo
#   INCREMENTAL  el resto de los días: los binary logs cerrados desde
#                el último backup (de cualquier tipo)
#
# Restauración: completo + último diferencial + incrementales posteriores
# (los binary logs se reaplican con mysqlbinlog, ver el paso a paso).
#
# Uso:  backup_bd.sh [completo|diferencial|incremental]
#       Sin argumento elige el tipo según la fecha de hoy.
#
# Archivos que genera en $DESTINO_LOCAL (y envía a la VM de backup):
#   bd_completo_FECHA.sql.gz
#   bd_diferencial_FECHA.tar.gz   bd_incremental_FECHA.tar.gz
# ==========================================================

umask 077
set -u

# ---------- Configuración (editar USUARIO_BACKUP) ----------
NOMBRE_BD="${NOMBRE_BD:-terrabit}"
DESTINO_LOCAL="${DESTINO_LOCAL:-/var/backups/terrabit-bd}"
RETENCION_LOCAL_DIAS="${RETENCION_LOCAL_DIAS:-45}"
USUARIO_BACKUP="${USUARIO_BACKUP:-CAMBIAR_USUARIO}"
IP_SERVIDOR_BACKUP="${IP_SERVIDOR_BACKUP:-192.168.100.30}"
DESTINO_REMOTO="${DESTINO_REMOTO:-/srv/backups/terrabit}"
# -----------------------------------------------------------

TIPO="${1:-auto}"
case "$TIPO" in
    auto|completo|diferencial|incremental) ;;
    *) echo "Uso: $0 [completo|diferencial|incremental]"; exit 2 ;;
esac

if [ "$USUARIO_BACKUP" = "CAMBIAR_USUARIO" ]; then
    echo "Editá USUARIO_BACKUP al principio de este script."; exit 2
fi

REPO="$DESTINO_LOCAL/binlogs"          # copia local de los binary logs
ESTADO_FILE="$DESTINO_LOCAL/estado.conf"
ENVIADOS="$DESTINO_LOCAL/enviados.txt"
LOG="$DESTINO_LOCAL/backup_bd.log"
mkdir -p "$DESTINO_LOCAL" "$REPO"
touch "$ENVIADOS"

# Una sola ejecución a la vez
exec 9>"$DESTINO_LOCAL/.lock"
flock -n 9 || { echo "Ya hay otro backup en ejecución."; exit 1; }

# Todo lo que se muestra también queda en el log
exec > >(tee -a "$LOG") 2>&1

fecha=$(date '+%Y%m%d_%H%M%S')
errores=0

echo "===== Backup de BD $(date) ====="

# --- Comprobaciones ---
if [ "$(mysql -N -B -e 'SELECT @@log_bin' 2>/dev/null)" != "1" ]; then
    echo "[-] El binary log no está activo o no se puede acceder a MySQL (¿root/sudo?)."
    exit 1
fi
BASENAME_LOG=$(mysql -N -B -e 'SELECT @@log_bin_basename')   # ej: /var/lib/mysql/binlog
DIR_BINLOG=$(dirname "$BASENAME_LOG")
PREFIJO=$(basename "$BASENAME_LOG")

num_de() { echo $((10#${1##*.})); }

guardar_estado() {
    cat > "$ESTADO_FILE.tmp" <<EOT
BASE_BINLOG="$BASE_BINLOG"
BASE_NUM=$BASE_NUM
BASE_POS=$BASE_POS
ULTIMO_NUM=$ULTIMO_NUM
EOT
    mv "$ESTADO_FILE.tmp" "$ESTADO_FILE"
}

# Binary logs cerrados (todos menos el último, que sigue abierto)
listar_cerrados() {
    mysql -N -B -e "SHOW BINARY LOGS" | awk '{print $1}' | sed '$d'
}

# --- Elección del tipo ---
if [ "$TIPO" = "auto" ]; then
    if [ "$(date +%d)" = "01" ]; then TIPO="completo"
    elif [ "$(date +%u)" = "7" ]; then TIPO="diferencial"
    else TIPO="incremental"; fi
fi

# Sin completo previo no hay base para diferencial ni incremental
if [ "$TIPO" != "completo" ]; then
    if [ -f "$ESTADO_FILE" ]; then
        source "$ESTADO_FILE"
    else
        echo "[i] No hay un backup completo previo: se hace uno completo."
        TIPO="completo"
    fi
fi
echo "Tipo: $TIPO"

# ---------------------------------------------------------
hacer_completo() {
    local arch="$DESTINO_LOCAL/bd_completo_$fecha.sql.gz" opt="--source-data=2" linea
    mysqldump --help 2>/dev/null | grep -q -- '--source-data' || opt="--master-data=2"

    mysqldump --single-transaction --flush-logs "$opt" --no-tablespaces \
              --routines --triggers "$NOMBRE_BD" | gzip > "$arch"
    if [ "${PIPESTATUS[0]}" -ne 0 ] || ! gzip -t "$arch" 2>/dev/null; then
        echo "[-] Error en mysqldump"; rm -f "$arch"; return 1
    fi

    # Binary log y posición donde quedó el dump
    linea=$(zcat "$arch" | head -n 100 | grep -m1 -E "(SOURCE|MASTER)_LOG_FILE")
    BASE_BINLOG=$(echo "$linea" | sed -E "s/.*_LOG_FILE='([^']+)'.*/\1/")
    BASE_POS=$(echo "$linea" | sed -E "s/.*_LOG_POS=([0-9]+).*/\1/")
    if [ -z "$linea" ] || [ -z "$BASE_BINLOG" ] || ! [[ "$BASE_POS" =~ ^[0-9]+$ ]]; then
        echo "[-] No se encontró la posición del binary log en el dump"; rm -f "$arch"; return 1
    fi
    BASE_NUM=$(num_de "$BASE_BINLOG")
    ULTIMO_NUM=$((BASE_NUM - 1))
    guardar_estado
    echo "[+] Completo: $arch ($(du -h "$arch" | cut -f1))"
    echo "    Binary log base: $BASE_BINLOG  posición: $BASE_POS"
}

hacer_binlogs() {
    local tipo="$1" desde f n hasta=0 lista=() tmp arch
    mysql -N -B -e "FLUSH BINARY LOGS" || { echo "[-] No se pudo cerrar el binary log"; return 1; }

    # 1. Copiar al repositorio local los binary logs cerrados desde el completo
    #    (así el diferencial no depende de que MySQL los conserve)
    while read -r f; do
        n=$(num_de "$f")
        [ "$n" -ge "$BASE_NUM" ] || continue
        if [ ! -f "$REPO/$f" ]; then
            cp -p "$DIR_BINLOG/$f" "$REPO/$f" || { echo "[-] No se pudo copiar $f (¿root?)"; return 1; }
        fi
    done < <(listar_cerrados)

    # 2. Elegir qué incluir
    if [ "$tipo" = "diferencial" ]; then desde=$BASE_NUM; else desde=$((ULTIMO_NUM + 1)); fi
    for f in $(ls "$REPO" | grep -E "^${PREFIJO}\.[0-9]+$" | sort); do
        n=$(num_de "$f")
        if [ "$n" -ge "$desde" ]; then lista+=("$f"); hasta=$n; fi
    done
    if [ ${#lista[@]} -eq 0 ]; then
        echo "[i] No hay binary logs nuevos para respaldar."; return 0
    fi

    # 3. Armar el archivo, con un texto que explica cómo restaurarlo
    tmp=$(mktemp -d)
    {
        echo "tipo=$tipo"
        echo "fecha=$fecha"
        echo "base_binlog=$BASE_BINLOG"
        echo "base_pos=$BASE_POS   (usar --start-position con este valor en el primer binary log)"
        echo "binlogs=${lista[*]}"
    } > "$tmp/info_${tipo}_$fecha.txt"
    arch="$DESTINO_LOCAL/bd_${tipo}_$fecha.tar.gz"
    if tar -czf "$arch" -C "$REPO" "${lista[@]}" -C "$tmp" "info_${tipo}_$fecha.txt"; then
        ULTIMO_NUM=$hasta
        guardar_estado
        echo "[+] ${tipo^}: $arch ($(du -h "$arch" | cut -f1)) - ${#lista[@]} binary log(s): ${lista[*]}"
    else
        echo "[-] Error al crear $arch"; rm -f "$arch"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
}

if [ "$TIPO" = "completo" ]; then
    hacer_completo || errores=$((errores + 1))
else
    hacer_binlogs "$TIPO" || errores=$((errores + 1))
fi

# --- Envío al servidor de backup (también reintenta lo que haya quedado pendiente) ---
for f in "$DESTINO_LOCAL"/bd_*; do
    [ -f "$f" ] || continue
    nombre=$(basename "$f")
    grep -qxF "$nombre" "$ENVIADOS" && continue
    if scp -o BatchMode=yes -o ConnectTimeout=15 "$f" \
           "${USUARIO_BACKUP}@${IP_SERVIDOR_BACKUP}:${DESTINO_REMOTO}/"; then
        echo "$nombre" >> "$ENVIADOS"
        echo "[+] Enviado al servidor de backup: $nombre"
    else
        echo "[-] No se pudo enviar $nombre (se reintenta en la próxima ejecución)"
        errores=$((errores + 1))
    fi
done

# --- Rotación local ---
find "$DESTINO_LOCAL" -maxdepth 1 -type f -name "bd_*" -mtime +"$RETENCION_LOCAL_DIAS" -delete
find "$REPO" -type f -mtime +"$RETENCION_LOCAL_DIAS" -delete

echo "===== Fin ($errores errores) ====="
exit $errores
