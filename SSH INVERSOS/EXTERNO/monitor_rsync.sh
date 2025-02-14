#!/bin/bash

# Configuración
BACKUP_DIR="/var/backups/back_cabildo/rsync"
ARCHIVE_DIR="/mnt/volume_nyc1_03/backups/backups_cabildo"
LOG_FILE="$BACKUP_DIR/rsyncd.log"
SCRIPT_DIR="/home/sis_backups_auto"
PROCESSED_FILES="/tmp/processed_backups"
EMAIL_SCRIPT="$SCRIPT_DIR/send_email.sh"
MOVE_EMAIL_SCRIPT="$SCRIPT_DIR/send_move_email.sh"
MIN_SPACE_FACTOR=3  
M0ONITOR_LOG="$SCRIPT_DIR/monitor.log"
SLEEP_TIME=3600

# Crear archivo de archivos procesados si no existe
touch "$PROCESSED_FILES"

# Función para logging
log_message() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    # También podemos guardar los logs en un archivo
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$SCRIPT_DIR/monitor.log"
}


# Función para obtener el tamaño promedio de los últimos backups
# Función para obtener el tamaño promedio de los últimos backups
get_average_backup_size() {
    #log_message "📊 Calculando tamaño promedio de backups..."
    
    # Usar un archivo temporal para almacenar los tamaños
    local temp_file=$(mktemp)
    find "$BACKUP_DIR" -name "expsisesmer_*.gz" -type f -printf "%s\n" | tail -n 5 > "$temp_file"
    
    if [ ! -s "$temp_file" ]; then
        log_message "⚠️ No se encontraron archivos de backup para calcular promedio"
        rm "$temp_file"
        echo 0
        return
    fi
    
    # Calcular el total y el conteo
    local total=0
    local count=0
    while read -r size; do
        total=$((total + size))
        count=$((count + 1))
    done < "$temp_file"
    
    rm "$temp_file"
    
    if [ $count -eq 0 ]; then
        log_message "⚠️ No se pudieron procesar los tamaños de los backups"
        echo 0
        return
    fi
    
    local average=$((total / count))
    #log_message "📊 Tamaño promedio calculado: $(format_size $average)"
    echo $average
}

# Función para convertir bytes a formato legible
format_size() {
    local size=$1
    if [ $size -ge 1073741824 ]; then
        echo "$(bc <<< "scale=2; $size/1073741824")GB"
    elif [ $size -ge 1048576 ]; then
        echo "$(bc <<< "scale=2; $size/1048576")MB"
    else
        echo "$(bc <<< "scale=2; $size/1024")KB"
    fi
}

# Función para verificar y gestionar espacio en disco
check_disk_space() {
    log_message "💾 Verificando espacio en disco..."
    local avg_size=$(get_average_backup_size)
    local required_space=$((avg_size * MIN_SPACE_FACTOR))
    local available_space=$(df --output=avail "$BACKUP_DIR" | tail -n1)
    available_space=$((available_space * 1024))
    
    log_message "📊 Espacio requerido: $(format_size $required_space)"
    log_message "📊 Espacio disponible: $(format_size $available_space)"
    
    if [ $available_space -lt $required_space ]; then
        log_message "⚠️ Espacio insuficiente, iniciando movimiento de archivos..."
        local files_to_move=()
        local moved_files=""
        
        while read -r file; do
            if [ $available_space -ge $required_space ]; then
                break
            fi
            
            local file_size=$(stat -c%s "$file")
            log_message "📦 Intentando mover archivo: $(basename "$file") ($(format_size $file_size))"
            
            if mv "$file" "$ARCHIVE_DIR/"; then
                files_to_move+=("$(basename "$file")")
                moved_files+="$(basename "$file") ($(format_size $file_size))\n"
                available_space=$((available_space + file_size))
                log_message "✅ Archivo movido exitosamente"
            else
                log_message "❌ Error al mover archivo: $(basename "$file")"
            fi
        done < <(find "$BACKUP_DIR" -name "expsisesmer_*.gz" -type f -printf "%T@ %p\n" | sort -n | cut -d' ' -f2-)
        
        if [ ${#files_to_move[@]} -gt 0 ]; then
            log_message "📧 Enviando notificación de archivos movidos..."
            local main_avail=$(df -h --output=avail "$BACKUP_DIR" | tail -n1)
            local main_total=$(df -h --output=size "$BACKUP_DIR" | tail -n1)
            local backup_avail=$(df -h --output=avail "$ARCHIVE_DIR" | tail -n1)
            local backup_total=$(df -h --output=size "$ARCHIVE_DIR" | tail -n1)
            
            "$MOVE_EMAIL_SCRIPT" \
                "SERVIDOR-BACKUPS" \
                "$(date +%s)" \
                "✅ Archivos movidos exitosamente" \
                "$main_avail" \
                "$main_total" \
                "$backup_avail" \
                "$backup_total" \
                "$moved_files"
            
            if [ $? -eq 0 ]; then
                log_message "✅ Notificación enviada exitosamente"
            else
                log_message "❌ Error al enviar notificación"
            fi
        fi
    else
        log_message "✅ Espacio en disco suficiente"
    fi
}

# Función para verificar si estamos en el horario de backup
check_backup_window() {
    local current_hour=$(date +%H)
    local current_time=$(date +%s)
    local today_20=$(date -d "$(date +%Y-%m-%d) 20:00:00" +%s)
    local tomorrow_02=$(date -d "$(date +%Y-%m-%d) 02:00:00 + 1 day" +%s)
    
    if [ $current_time -ge $today_20 ] || [ $current_time -le $tomorrow_02 ]; then
        return 0
    else
        return 1
    fi
}

# Función para procesar archivo de backup
process_backup() {
    local backup_file="$1"
    log_message "🔍 Procesando archivo: $backup_file"
    
    if grep -q "^$backup_file$" "$PROCESSED_FILES"; then
        log_message "ℹ️ Archivo ya procesado anteriormente, omitiendo"
        return
    fi
    
    check_disk_space
    
    local session_lines
    if session_lines=$(grep -B2 -A1 "$backup_file" "$LOG_FILE"); then
        log_message "📋 Encontradas líneas de log relacionadas"
        local start_time=$(echo "$session_lines" | grep "connect from" | head -1 | cut -d' ' -f1,2)
        local start_timestamp=$(date -d "$start_time" +%s)
        local end_time=$(date +%s)
        
        local diff=$((end_time - start_timestamp))
        local minutes=$((diff / 60))
        local seconds=$((diff % 60))
        
        log_message "⏱️ Tiempo de proceso: $minutes minutos y $seconds segundos"
        
        local status
        if grep -q "error\|failed\|failure" <<< "$session_lines"; then
            status="❌ Con Errores"
            log_message "❌ Se encontraron errores en el proceso"
        else
            status="✅ Exitoso"
            local expected_size=$(echo "$session_lines" | grep "total size" | awk '{print $NF}')
            local actual_size=$(stat -c%s "$BACKUP_DIR/$backup_file")
            
            log_message "📊 Tamaño esperado: $(format_size $expected_size)"
            log_message "📊 Tamaño actual: $(format_size $actual_size)"
            
            if [ "$actual_size" != "$expected_size" ]; then
                status="❌ Error: Tamaño de archivo incorrecto"
                log_message "❌ Error de tamaño en el archivo"
            fi
        fi
        
        # Crear archivo temporal para los logs
        local temp_log_file=$(mktemp)
        echo "$session_lines" > "$temp_log_file"
        
        log_message "📧 Enviando notificación de backup..."
        "$EMAIL_SCRIPT" \
            "SERVIDOR-BACKUPS" \
            "$start_timestamp" \
            "$minutes" \
            "$seconds" \
            "$temp_log_file"
        
        local email_status=$?
        # Eliminar archivo temporal
        rm -f "$temp_log_file"
        
        if [ $email_status -eq 0 ]; then
            log_message "✅ Notificación enviada exitosamente"
            echo "$backup_file" >> "$PROCESSED_FILES"
            log_message "✅ Archivo marcado como procesado"
        else
            log_message "❌ Error al enviar notificación"
        fi
    else
        log_message "❌ No se encontraron logs relacionados con el archivo"
    fi
}

# Función para verificar si falta el backup
check_missing_backup() {
    if check_backup_window; then
        local today=$(date +%Y%m%d)
        local backup_pattern="expsisesmer_${today}*.gz"
        
        if ! ls $BACKUP_DIR/$backup_pattern &> /dev/null; then
            # Si no hay backup y estamos después de las 23:00
            if [ $(date +%H) -ge 23 ]; then
                # Crear archivo temporal para el mensaje
                local temp_log_file=$(mktemp)
                echo "❌ ALERTA: No se ha recibido el backup del día $(date +%Y-%m-%d)" > "$temp_log_file"
                
                # Enviar notificación de backup faltante
                "$EMAIL_SCRIPT" \
                    "SERVIDOR-BACKUPS" \
                    "$(date +%s)" \
                    "0" \
                    "0" \
                    "$temp_log_file"
                
                local email_status=$?
                rm -f "$temp_log_file"
                
                if [ $email_status -ne 0 ]; then
                    log_message "❌ Error al enviar notificación de backup faltante"
                fi
            fi
        fi
    fi
}

# Función para test
run_tests() {
    echo "🧪 Iniciando pruebas del sistema de monitoreo..."
    
    # Crear directorio temporal para pruebas
    TEST_DIR=$(mktemp -d)
    TEST_BACKUP_DIR="$TEST_DIR/backups"
    TEST_ARCHIVE_DIR="$TEST_DIR/archive"
    TEST_LOG="$TEST_DIR/rsyncd.log"
    
    mkdir -p "$TEST_BACKUP_DIR" "$TEST_ARCHIVE_DIR"
    
    echo "📁 Creando archivos de prueba..."
    
    # Crear archivos de backup simulados
    dd if=/dev/zero of="$TEST_BACKUP_DIR/expsisesmer_20250214-164432.gz" bs=1M count=100
    dd if=/dev/zero of="$TEST_BACKUP_DIR/expsisesmer_20250213-164432.gz" bs=1M count=100
    
    # Crear log simulado
    cat > "$TEST_LOG" << EOL
2025/02/14 17:14:17 [2854147] connect from 102.57.46.186.static.anycast.cnt-grms.ec (186.46.57.102)
2025/02/14 17:14:17 [2854147] rsync allowed access on module backup from 102.57.46.186.static.anycast.cnt-grms.ec (186.46.57.102)
2025/02/14 22:14:17 [2854147] receiving file list
2025/02/14 22:20:09 [2854147] recv expsisesmer_20250214-164432.gz
2025/02/14 22:20:09 [2854147] sent 62 bytes  received 104857600 bytes  total size 104857600
EOL
    
    echo "🧪 Test 1: Procesamiento de backup exitoso"
    TEST_BACKUP_DIR=$TEST_BACKUP_DIR \
    TEST_ARCHIVE_DIR=$TEST_ARCHIVE_DIR \
    TEST_LOG=$TEST_LOG \
    process_backup "expsisesmer_20250214-164432.gz"
    
    echo "🧪 Test 2: Simulando espacio insuficiente"
    # Crear varios archivos grandes
    for i in {1..5}; do
        dd if=/dev/zero of="$TEST_BACKUP_DIR/expsisesmer_202502${i}-164432.gz" bs=1M count=200
    done
    
    TEST_BACKUP_DIR=$TEST_BACKUP_DIR \
    TEST_ARCHIVE_DIR=$TEST_ARCHIVE_DIR \
    TEST_LOG=$TEST_LOG \
    check_disk_space
    
    echo "🧪 Test 3: Verificación de ventana horaria"
    check_backup_window
    current_hour=$(date +%H)
    if [ $current_hour -ge 20 ] || [ $current_hour -le 02 ]; then
        echo "✅ Estamos en ventana horaria correcta"
    else
        echo "ℹ️ Fuera de ventana horaria (8 PM - 2 AM)"
    fi
    
    echo "🧪 Test 4: Simulando backup faltante"
    rm "$TEST_BACKUP_DIR/expsisesmer_$(date +%Y%m%d)"* 2>/dev/null
    TEST_BACKUP_DIR=$TEST_BACKUP_DIR \
    check_missing_backup
    
    echo "🧪 Test 5: Probando formateo de tamaños"
    sizes=(1024 1048576 1073741824 5368709120)
    for size in "${sizes[@]}"; do
        echo "Tamaño $size bytes = $(format_size $size)"
    done
    
    echo "🧪 Test 6: Verificando promedio de tamaños"
    TEST_BACKUP_DIR=$TEST_BACKUP_DIR \
    avg_size=$(get_average_backup_size)
    echo "Tamaño promedio de backups: $(format_size $avg_size)"
    
    echo "🧪 Limpiando archivos de prueba..."
    rm -rf "$TEST_DIR"
    
    echo "✅ Pruebas completadas"
    exit 0
}


# Ciclo principal
# Ciclo principal
if [ "$1" = "test" ]; then
    log_message "🧪 Iniciando modo de prueba..."
    run_tests
else
    log_message "🔄 Iniciando monitoreo en modo normal..."
    # Crear archivo de log si no existe
    touch "$MONITOR_LOG"
    while true; do
        check_disk_space
        
        for backup_file in "$BACKUP_DIR"/expsisesmer_*.gz; do
            if [ -f "$backup_file" ]; then
                process_backup "$(basename "$backup_file")"
            fi
        done
        
        check_missing_backup
        log_message "💤 Esperando 1 hora antes de la siguiente verificación..."
        sleep $SLEEP_INTERVAL
    done
fi