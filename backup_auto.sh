#!/bin/bash
# ==========================================
# BACKUP AUTOMÁTICO - lo ejecuta cron (sin menú, sin preguntas)
# Proyecto terrabit
# ==========================================
# Estrategia de respaldo:
#   Archivos del proyecto (tar con --listed-incremental)
#     - COMPLETO     : el día 1 de cada mes
#     - DIFERENCIAL  : todos los domingos
#                      (cambios desde el último completo)
#     - INCREMENTAL  : el resto de los días
#                      (cambios desde el último backup, de cualquier tipo)
#   Base de datos
#     - Dump completo en cada ejecución (mysqldump no es incremental;
#       la base es chica, así que el costo es bajo)
#
# Uso:  backup_auto.sh [completo|diferencial|incremental]
#       Sin argumento elige el tipo según la fecha de hoy.
#
# Pasos: 1) archivos  2) base de datos  3) envío al Servidor 3 por SCP
#        4) rotación local (DIAS_RETENCION_LOCAL, usar 35 o más)

umask 077

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR_SCRIPT" || exit 1
source ./config.sh
source ./modulos/comun.sh

TIPO="${1:-auto}"
case "$TIPO" in
    auto|completo|diferencial|incremental) ;;
    *) echo "Uso: $0 [completo|diferencial|incremental]"; exit 2 ;;
esac

# Elección automática según la fecha (día 1 > domingo > resto)
if [ "$TIPO" = "auto" ]; then
    if [ "$(date +%d)" = "01" ]; then
        TIPO="completo"
    elif [ "$(date +%u)" = "7" ]; then
        TIPO="diferencial"
    else
        TIPO="incremental"
    fi
fi

fecha=$(date '+%Y%m%d_%H%M%S')
errores=0
enviados=()

# Archivos de control de tar (snapshots). Van en una subcarpeta oculta
# para que la rotación (que solo mira archivos sueltos) no los borre.
SNAR_DIR="$DESTINO_BACKUPS_LOCAL/.snar"
SNAR_CADENA="$SNAR_DIR/cadena.snar"    # estado tras el último backup (cualquier tipo)
SNAR_BASE="$SNAR_DIR/base.snar"        # estado tras el último completo
SNAR_TRABAJO="$SNAR_DIR/trabajo.snar"  # copia temporal de trabajo

mkdir -p "$DESTINO_BACKUPS_LOCAL" "$SNAR_DIR"
echo "===== Backup automático $(date) - tipo: $TIPO ====="

# --- 1. Archivos del proyecto ---
if [ -d "$RUTA_PROYECTO" ]; then
    # Sin un completo previo no se puede hacer diferencial ni incremental
    if [ "$TIPO" != "completo" ] && { [ ! -f "$SNAR_BASE" ] || [ ! -f "$SNAR_CADENA" ]; }; then
        echo "[i] No hay un backup completo previo: se hace uno completo."
        TIPO="completo"
    fi

    # Se trabaja siempre sobre una copia del snapshot; solo se confirma si tar salió bien
    rm -f "$SNAR_TRABAJO"
    case "$TIPO" in
        incremental) cp "$SNAR_CADENA" "$SNAR_TRABAJO" ;;
        diferencial) cp "$SNAR_BASE"   "$SNAR_TRABAJO" ;;
        completo)    : ;;   # sin snapshot previo: tar lo crea y guarda todo
    esac

    arch_app="$DESTINO_BACKUPS_LOCAL/auto_proyecto_${TIPO}_$fecha.tar.gz"
    tar --listed-incremental="$SNAR_TRABAJO" -czf "$arch_app" \
        -C "$(dirname "$RUTA_PROYECTO")" "$(basename "$RUTA_PROYECTO")"
    rc=$?
    # tar devuelve 1 si algún archivo cambió mientras se leía: es una advertencia
    if [ $rc -le 1 ]; then
        cp "$SNAR_TRABAJO" "$SNAR_CADENA"
        [ "$TIPO" = "completo" ] && cp "$SNAR_TRABAJO" "$SNAR_BASE"
        rm -f "$SNAR_TRABAJO"
        echo "[+] Proyecto ($TIPO): $arch_app ($(du -h "$arch_app" | cut -f1))"
        enviados+=("$arch_app")
    else
        echo "[-] Error en tar ($TIPO), código $rc"
        rm -f "$arch_app" "$SNAR_TRABAJO"
        errores=$((errores + 1))
    fi
else
    echo "[i] $RUTA_PROYECTO no existe en este servidor, se omite."
fi

# --- 2. Base de datos (dump completo) ---
if [ -f "$CNF_BACKUP_AUTO" ] && command -v mysqldump &>/dev/null; then
    arch_bd="$DESTINO_BACKUPS_LOCAL/auto_bd_${NOMBRE_BD}_$fecha.sql.gz"
    if mysqldump --defaults-extra-file="$CNF_BACKUP_AUTO" --single-transaction \
                 --no-tablespaces --routines --triggers "$NOMBRE_BD" | gzip > "$arch_bd" \
       && [ "${PIPESTATUS[0]}" -eq 0 ]; then
        echo "[+] Base de datos respaldada: $arch_bd"
        enviados+=("$arch_bd")
    else
        echo "[-] Error en mysqldump"; rm -f "$arch_bd"; errores=$((errores + 1))
    fi
else
    echo "[i] Sin credenciales en $CNF_BACKUP_AUTO o sin mysqldump: se omite la BD."
fi

# --- 3. Envío al servidor de respaldos ---
for f in "${enviados[@]}"; do
    # BatchMode: si la llave no está configurada falla al instante
    # en vez de quedarse esperando una contraseña que nadie va a escribir
    if scp -o BatchMode=yes -o ConnectTimeout=15 "$f" \
           "${USUARIO_BACKUP}@${IP_SERVIDOR_BACKUP}:${DESTINO_BACKUPS_REMOTO}/"; then
        echo "[+] Enviado al Servidor 3: $(basename "$f")"
    else
        echo "[-] No se pudo enviar $(basename "$f") al Servidor 3"; errores=$((errores + 1))
    fi
done

# --- 4. Rotación local ---
# Con completos mensuales conviene DIAS_RETENCION_LOCAL >= 35 en config.sh
find "$DESTINO_BACKUPS_LOCAL" -maxdepth 1 -type f -name "auto_*" -mtime +"$DIAS_RETENCION_LOCAL" -delete

if [ $errores -eq 0 ]; then
    log_accion respaldos "Backup automático OK (tipo $TIPO, ${#enviados[@]} archivos)"
else
    log_accion respaldos "Backup automático ($TIPO) con $errores error(es)"
fi
echo "===== Fin ($errores errores) ====="
exit $errores
