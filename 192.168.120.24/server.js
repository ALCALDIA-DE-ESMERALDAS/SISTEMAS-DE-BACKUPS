import express from "express";
import { exec } from "child_process";
import fs, { promises as fsPromises } from "fs";
import path from "path";
import sql from "mssql";
import dotenv from "dotenv";
import net from "net";
import { EventEmitter } from "events";
import { fileURLToPath } from "url";
import { dirname } from "path";

// Cargar variables de entorno
dotenv.config();

// Obtener __dirname en ES modules
const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const app = express();

// Middleware CORS - DEBE IR PRIMERO
app.use((req, res, next) => {
  res.header("Access-Control-Allow-Origin", "*");
  res.header("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS");
  res.header(
    "Access-Control-Allow-Headers",
    "Origin, X-Requested-With, Content-Type, Accept, Authorization, Cache-Control"
  );

  // Responder a preflight requests
  if (req.method === "OPTIONS") {
    res.sendStatus(200);
  } else {
    next();
  }
});

app.use(express.json());

// Middleware para logging mejorado - TEMPRANO
app.use((req, res, next) => {
  const timestamp = new Date().toISOString();
  console.log(`${timestamp} - ${req.method} ${req.path}`);
  next();
});

// Validar variables de entorno requeridas
const requiredEnvVars = [
  "SQL_SERVER",
  "SQL_USER",
  "SQL_PASSWORD",
  "RSYNC_HOST",
  "RSYNC_USER",
  "RSYNC_MODULE",
  "RSYNC_PASSWORD_FILE",
];

const missingVars = requiredEnvVars.filter((varName) => !process.env[varName]);
if (missingVars.length > 0) {
  console.error("❌ Variables de entorno faltantes:", missingVars.join(", "));
  console.error("💡 Copia .env.example a .env y configura los valores");
  process.exit(1);
}

// Configuración de SQL Server desde variables de entorno
const sqlConfig = {
  user: process.env.SQL_USER,
  password: process.env.SQL_PASSWORD,
  database: process.env.SQL_DATABASE || "master",
  server: process.env.SQL_SERVER,
  port: parseInt(process.env.SQL_PORT) || 1433,
  options: {
    encrypt: process.env.SQL_ENCRYPT === "true",
    trustServerCertificate: process.env.SQL_TRUST_CERTIFICATE === "true",
    requestTimeout: parseInt(process.env.SQL_REQUEST_TIMEOUT) || 300000,
    connectionTimeout: parseInt(process.env.SQL_CONNECTION_TIMEOUT) || 30000,
  },
};

// Configuración rsync desde variables de entorno
const rsyncConfig = {
  host: process.env.RSYNC_HOST,
  user: process.env.RSYNC_USER,
  module: process.env.RSYNC_MODULE,
  port: process.env.RSYNC_PORT || "9000",
  passwordFile: process.env.RSYNC_PASSWORD_FILE,
};

// Bases de datos disponibles desde variable de entorno
const availableDatabases = process.env.AVAILABLE_DATABASES
  ? process.env.AVAILABLE_DATABASES.split(",").map((db) => db.trim())
  : ["biometricos", "security_db"];

// CORREGIDO: Usar siempre process.cwd() para directorios
const tempDir = path.join(process.cwd(), "temp");
const backupDir = path.join(process.cwd(), "backups");

// EventEmitter para manejar progress en tiempo real
const backupProgress = new EventEmitter();

// ============ RUTAS PRINCIPALES PRIMERO ============

// RUTA RAÍZ - DEBE IR ANTES DE LOS OTROS MIDDLEWARES
app.get("/", (req, res) => {
  const htmlPath = path.join(__dirname, "backup_client.html");

  console.log(`📁 Buscando archivo HTML en: ${htmlPath}`);

  // Verificar si el archivo HTML existe
  if (fs.existsSync(htmlPath)) {
    console.log("✅ Archivo HTML encontrado, enviando...");
    res.sendFile(htmlPath);
  } else {
    console.log("⚠️ Archivo HTML no encontrado, mostrando página de respaldo");
    // Si no existe el archivo, mostrar una página de bienvenida simple
    res.send(`
      <!DOCTYPE html>
      <html lang="es">
      <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>Sistema de Backups - API</title>
        <style>
          body { 
            font-family: Arial, sans-serif; 
            max-width: 800px; 
            margin: 50px auto; 
            padding: 20px;
            background: #f5f5f5;
          }
          .container {
            background: white;
            padding: 30px;
            border-radius: 10px;
            box-shadow: 0 2px 10px rgba(0,0,0,0.1);
          }
          h1 { color: #2c3e50; }
          .endpoint { 
            background: #ecf0f1; 
            padding: 10px; 
            margin: 5px 0; 
            border-radius: 5px;
            font-family: monospace;
          }
          .status { color: #27ae60; font-weight: bold; }
          .error { color: #e74c3c; font-weight: bold; }
        </style>
      </head>
      <body>
        <div class="container">
          <h1>🚀 Sistema de Backups - API</h1>
          <p class="status">✅ Servidor funcionando correctamente</p>
          <p class="error">⚠️ Archivo de interfaz no encontrado: backup_client.html</p>
          <p><strong>Ubicación esperada:</strong> <code>${htmlPath}</code></p>
          <p>Para usar la interfaz web completa, asegúrate de que el archivo <code>backup_client.html</code> esté en el mismo directorio que <code>server.js</code>.</p>
          
          <h2>📋 Endpoints disponibles:</h2>
          <div class="endpoint">GET  /status</div>
          <div class="endpoint">GET  /databases</div>
          <div class="endpoint">GET  /test-connection</div>
          <div class="endpoint">GET  /test-rsync</div>
          <div class="endpoint">GET  /progress/:sessionId</div>
          <div class="endpoint">POST /backup/:database</div>
          <div class="endpoint">POST /backup/all</div>
          
          <h2>🔧 Configuración actual:</h2>
          <p><strong>Bases de datos:</strong> ${availableDatabases.join(
            ", "
          )}</p>
          <p><strong>SQL Server:</strong> ${sqlConfig.server}:${
      sqlConfig.port
    }</p>
          <p><strong>Rsync Server:</strong> ${rsyncConfig.host}:${
      rsyncConfig.port
    }</p>
          <p><strong>Directorio temporal:</strong> ${tempDir}</p>
          
          <h2>🔧 Diagnóstico:</h2>
          <p><strong>Directorio actual:</strong> <code>${__dirname}</code></p>
          <p><strong>Archivos en directorio:</strong></p>
          <ul>
            ${fs
              .readdirSync(__dirname)
              .map((file) => `<li>${file}</li>`)
              .join("")}
          </ul>
        </div>
      </body>
      </html>
    `);
  }
});

// ============ ARCHIVOS ESTÁTICOS ============
// Servir archivos estáticos desde el directorio actual
app.use(express.static(__dirname));

// ============ MIDDLEWARES ESPECÍFICOS ============

// Middleware para validar configuración
app.use((req, res, next) => {
  if (req.path.includes("/backup/") && req.method === "POST") {
    try {
      // Verificar que el directorio temp existe
      if (!fs.existsSync(tempDir)) {
        fs.mkdirSync(tempDir, { recursive: true });
        console.log(`📁 Directorio temporal creado: ${tempDir}`);
      }
    } catch (error) {
      return res.status(500).json({
        success: false,
        error: "No se pudo crear el directorio temporal",
        details: error.message,
      });
    }
  }
  next();
});

// ============ FUNCIONES AUXILIARES ============

// Función para emitir progress
function emitProgress(sessionId, step, message, percentage = null) {
  const progressData = {
    sessionId,
    step,
    message,
    percentage,
    timestamp: new Date().toISOString(),
  };

  console.log(
    `📊 [${sessionId}] ${step}: ${message}${
      percentage ? ` (${percentage}%)` : ""
    }`
  );
  backupProgress.emit("progress", progressData);
  return progressData;
}

// ============ ENDPOINTS API ============

// Endpoint para Server-Sent Events (progress en tiempo real)
app.get("/progress/:sessionId", (req, res) => {
  const { sessionId } = req.params;

  res.writeHead(200, {
    "Content-Type": "text/event-stream",
    "Cache-Control": "no-cache",
    Connection: "keep-alive",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Cache-Control",
  });

  const progressHandler = (data) => {
    if (data.sessionId === sessionId) {
      res.write(`data: ${JSON.stringify(data)}\n\n`);
    }
  };

  backupProgress.on("progress", progressHandler);

  // Enviar mensaje inicial
  res.write(
    `data: ${JSON.stringify({
      sessionId,
      step: "connected",
      message: "Conectado al sistema de progress",
      timestamp: new Date().toISOString(),
    })}\n\n`
  );

  // Cleanup cuando el cliente se desconecta
  req.on("close", () => {
    backupProgress.removeListener("progress", progressHandler);
  });
});

// Endpoint principal para backup con progress
app.post("/backup/:database", async (req, res) => {
  const { database } = req.params;
  const sessionId = `backup_${database}_${Date.now()}`;

  // Validar que la base de datos existe en nuestra lista
  if (!availableDatabases.includes(database)) {
    return res.status(400).json({
      success: false,
      error: `Base de datos no válida. Disponibles: ${availableDatabases.join(
        ", "
      )}`,
    });
  }

  const timestamp =
    new Date().toISOString().replace(/[:.]/g, "-").split("T")[0] +
    "_" +
    new Date().toTimeString().split(" ")[0].replace(/:/g, "-");

  const backupFileName = `${database}_${timestamp}.bak`;
  const backupPath = path.join(backupDir, backupFileName);

  try {
    // Enviar respuesta inmediata con sessionId para seguimiento
    res.json({
      success: true,
      message: "Backup iniciado",
      sessionId,
      database,
      filename: backupFileName,
      progressUrl: `/progress/${sessionId}`,
    });

    emitProgress(sessionId, "init", "Iniciando proceso de backup");

    // Crear directorio temporal si no existe
    await fsPromises.mkdir(backupDir, { recursive: true });
    emitProgress(sessionId, "setup", "Directorio temporal preparado");

    console.log(`Iniciando backup de ${database}...`);
    emitProgress(
      sessionId,
      "backup_start",
      `Creando backup de base de datos ${database}`,
      10
    );

    // 1. Crear backup
    await createDatabaseBackup(database, backupPath, sessionId);
    emitProgress(
      sessionId,
      "backup_complete",
      `Backup creado: ${backupFileName}`,
      40
    );

    // 2. Verificar que el archivo existe y obtener su tamaño
    try {
      const stats = await fsPromises.stat(backupPath);
      const fileSizeMB = Math.round(stats.size / (1024 * 1024));
      console.log(`Tamaño del backup: ${fileSizeMB} MB`);
      emitProgress(
        sessionId,
        "backup_verified",
        `Backup verificado - Tamaño: ${fileSizeMB} MB`,
        50
      );

      // 3. Transferir a servidor rsync
      emitProgress(
        sessionId,
        "transfer_start",
        "Iniciando transferencia al servidor de backups",
        60
      );
      await transferToRsync(backupPath, backupFileName, sessionId);
      emitProgress(
        sessionId,
        "transfer_complete",
        "Transferencia completada exitosamente",
        90
      );

      // 4. Limpiar archivo local
      await fsPromises.unlink(backupPath);
      emitProgress(sessionId, "cleanup", "Archivo local limpiado", 95);

      emitProgress(
        sessionId,
        "success",
        `Backup de ${database} completado exitosamente`,
        100
      );
    } catch (statError) {
      throw new Error(
        `El archivo de backup no se creó correctamente: ${statError.message}`
      );
    }
  } catch (error) {
    console.error("Error en backup:", error);
    emitProgress(sessionId, "error", `Error: ${error.message}`, null);

    // Limpiar archivo en caso de error
    try {
      await fsPromises.access(backupPath);
      await fsPromises.unlink(backupPath);
      emitProgress(
        sessionId,
        "cleanup_error",
        "Archivo temporal limpiado tras error"
      );
    } catch (cleanupError) {
      console.error("Error limpiando archivo:", cleanupError.message);
    }
  }
});

// Backup de todas las bases de datos con progress
app.post("/backup/all", async (req, res) => {
  const sessionId = `backup_all_${Date.now()}`;
  const results = [];

  // Respuesta inmediata
  res.json({
    success: true,
    message: "Backup masivo iniciado",
    sessionId,
    databases: availableDatabases,
    progressUrl: `/progress/${sessionId}`,
  });

  emitProgress(
    sessionId,
    "init",
    `Iniciando backup de ${availableDatabases.length} bases de datos`
  );

  let completedCount = 0;
  const totalDatabases = availableDatabases.length;

  for (const database of availableDatabases) {
    try {
      const dbProgress = Math.round((completedCount / totalDatabases) * 100);
      emitProgress(
        sessionId,
        "db_start",
        `Procesando ${database} (${completedCount + 1}/${totalDatabases})`,
        dbProgress
      );

      const timestamp =
        new Date().toISOString().replace(/[:.]/g, "-").split("T")[0] +
        "_" +
        new Date().toTimeString().split(" ")[0].replace(/:/g, "-");

      const backupFileName = `${database}_${timestamp}.bak`;
      const backupPath = path.join(backupDir, backupFileName);

      await createDatabaseBackup(database, backupPath, sessionId);
      await transferToRsync(backupPath, backupFileName, sessionId);

      const stats = await fsPromises.stat(backupPath);
      const fileSizeMB = Math.round(stats.size / (1024 * 1024));

      await fsPromises.unlink(backupPath);

      results.push({
        database,
        success: true,
        filename: backupFileName,
        sizeMB: fileSizeMB,
      });

      completedCount++;
      const finalProgress = Math.round((completedCount / totalDatabases) * 100);
      emitProgress(
        sessionId,
        "db_complete",
        `${database} completado exitosamente`,
        finalProgress
      );
    } catch (error) {
      console.error(`Error en backup de ${database}:`, error.message);
      emitProgress(
        sessionId,
        "db_error",
        `Error en ${database}: ${error.message}`
      );

      results.push({
        database,
        success: false,
        error: error.message,
      });

      completedCount++;
    }
  }

  const successCount = results.filter((r) => r.success).length;
  const failureCount = results.filter((r) => !r.success).length;

  emitProgress(
    sessionId,
    "complete",
    `Proceso completado: ${successCount} exitosos, ${failureCount} errores`,
    100
  );
});

// Función para crear backup de base de datos con progress
async function createDatabaseBackup(database, backupPath, sessionId) {
  let pool;
  try {
    pool = await sql.connect(sqlConfig);
    emitProgress(sessionId, "sql_connected", "Conectado a SQL Server");

    // IMPORTANTE: Verificar que el directorio de destino existe
    const backupDir = path.dirname(backupPath);
    await fsPromises.mkdir(backupDir, { recursive: true });

    // Verificar que podemos escribir en el directorio
    try {
      const testFile = path.join(backupDir, `test_${Date.now()}.tmp`);
      await fsPromises.writeFile(testFile, "test");
      await fsPromises.unlink(testFile);
      emitProgress(
        sessionId,
        "permissions_ok",
        "Permisos de escritura verificados"
      );
    } catch (permError) {
      throw new Error(
        `No se puede escribir en el directorio de destino: ${permError.message}`
      );
    }

    // Escapar correctamente la ruta para SQL Server con comillas dobles
    // SQL Server requiere comillas dobles para rutas con espacios
    const sqlBackupPath = `N'${backupPath.replace(/'/g, "''")}'`;

    // Consulta mejorada con mejor manejo de errores
    const query = `
    -- Verificar que la base de datos existe y está online
    IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = '${database}' AND state = 0)
    BEGIN
      RAISERROR('La base de datos ${database} no existe o no está online', 16, 1)
      RETURN
    END
    
    -- Realizar el backup con ruta escapada correctamente
    BACKUP DATABASE [${database}] 
    TO DISK = ${sqlBackupPath}
    WITH 
      FORMAT,
      COMPRESSION,
      CHECKSUM,
      STATS = 10,
      DESCRIPTION = 'Backup automatico generado por sistema Node.js'
  `;

    console.log(`Ejecutando backup SQL para ${database}...`);
    console.log(`Ruta de destino: ${backupPath}`);
    console.log(`Comando SQL: ${query.replace(/\s+/g, " ").trim()}`);

    emitProgress(
      sessionId,
      "sql_executing",
      "Ejecutando comando SQL de backup"
    );

    const request = pool.request();
    request.timeout = 600000; // 10 minutos

    // Configurar manejo de mensajes de SQL Server
    request.on("info", (info) => {
      console.log(`SQL Info: ${info.message}`);
      if (info.message.includes("%")) {
        // Extraer porcentaje del mensaje SQL
        const match = info.message.match(/(\d+)\s*percent/i);
        if (match) {
          const percent = parseInt(match[1]);
          emitProgress(
            sessionId,
            "sql_progress",
            `Backup SQL en progreso: ${percent}%`,
            10 + percent * 0.3 // Mapear 0-100% de SQL a 10-40% del proceso total
          );
        }
      }
    });

    const result = await request.query(query);

    // Dar un pequeño delay para que SQL Server termine de escribir
    await new Promise((resolve) => setTimeout(resolve, 1000));

    // Verificar inmediatamente que el archivo se creó
    try {
      await fsPromises.access(backupPath, fs.constants.F_OK);
      const stats = await fsPromises.stat(backupPath);

      if (stats.size === 0) {
        throw new Error("El archivo de backup se creó pero está vacío");
      }

      const fileSizeMB = Math.round(stats.size / (1024 * 1024));
      console.log(
        `✅ Backup SQL completado y verificado para ${database} - Tamaño: ${fileSizeMB} MB`
      );
      emitProgress(
        sessionId,
        "sql_complete",
        `Backup SQL completado y verificado - Tamaño: ${fileSizeMB} MB`
      );
    } catch (accessError) {
      // Intentar listar el directorio para diagnosticar
      try {
        const files = await fsPromises.readdir(backupDir);
        console.log(`Archivos en directorio de backup: ${files.join(", ")}`);
        emitProgress(
          sessionId,
          "diagnostic",
          `Archivos en directorio: ${files.length} encontrados`
        );
      } catch (listError) {
        console.log(`No se pudo listar el directorio: ${listError.message}`);
      }

      throw new Error(
        `El archivo de backup no se creó en la ruta esperada: ${backupPath}. ${accessError.message}`
      );
    }

    return result;
  } catch (error) {
    console.error(`Error detallado en backup de ${database}:`, error);

    // Proporcionar información adicional de diagnóstico
    let errorMessage = error.message;

    if (error.message.includes("BACKUP DATABASE is terminating abnormally")) {
      errorMessage = `Error de permisos o ruta inválida. Verifique que:
        1. SQL Server tenga permisos de escritura en: ${path.dirname(
          backupPath
        )}
        2. La ruta no contenga caracteres especiales problemáticos
        3. El servicio SQL Server se ejecute con permisos adecuados
        Error original: ${error.message}`;
    } else if (error.message.includes("Cannot open backup device")) {
      errorMessage = `No se puede acceder a la ruta de backup. Verifique permisos y que la ruta exista: ${backupPath}`;
    } else if (error.message.includes("Operating system error")) {
      errorMessage = `Error del sistema operativo. Verifique permisos de SQL Server en la ruta: ${path.dirname(
        backupPath
      )}`;
    }

    emitProgress(
      sessionId,
      "sql_error",
      `Error en backup SQL: ${errorMessage}`
    );
    throw new Error(`Error en backup SQL de ${database}: ${errorMessage}`);
  } finally {
    if (pool) {
      await pool.close();
      emitProgress(sessionId, "sql_disconnected", "Desconectado de SQL Server");
    }
  }
}

// Función auxiliar para verificar y crear directorio seguro para SQL Server
async function ensureSqlServerAccessiblePath(originalPath, sessionId) {
  // Si la ruta tiene espacios o caracteres problemáticos, sugerir una alternativa
  const hasSpaces = originalPath.includes(" ");
  const hasSpecialChars = /[^\w\\\/:.-]/.test(originalPath);

  if (hasSpaces || hasSpecialChars) {
    // Crear una ruta alternativa en C:\temp si estamos en Windows
    if (process.platform === "win32") {
      const safeTempDir = "C:\\Temp\\SQLBackups";
      const fileName = path.basename(originalPath);
      const safePath = path.join(safeTempDir, fileName);

      try {
        await fsPromises.mkdir(safeTempDir, { recursive: true });
        emitProgress(
          sessionId,
          "path_alternative",
          `Usando ruta alternativa segura: ${safePath}`
        );
        return safePath;
      } catch (error) {
        emitProgress(
          sessionId,
          "path_warning",
          `No se pudo crear ruta alternativa: ${error.message}`
        );
      }
    }
  }

  return originalPath;
}

// Función para verificar permisos de SQL Server
async function checkSqlServerPermissions(testPath, sessionId) {
  let pool;
  try {
    pool = await sql.connect(sqlConfig);

    const testQuery = `
      DECLARE @TestPath NVARCHAR(500) = '${testPath.replace(/\\/g, "\\\\")}'
      EXEC xp_cmdshell 'echo test > "' + @TestPath + '"'
    `;

    const result = await pool.request().query(testQuery);
    emitProgress(
      sessionId,
      "permissions_test",
      "Verificando permisos de SQL Server"
    );

    // Verificar si el archivo de test se creó
    try {
      await fsPromises.access(testPath);
      await fsPromises.unlink(testPath);
      return true;
    } catch {
      return false;
    }
  } catch (error) {
    console.log(
      "No se pudo verificar permisos con xp_cmdshell:",
      error.message
    );
    return null; // No se pudo determinar
  } finally {
    if (pool) {
      await pool.close();
    }
  }
}

// Función para transferir archivo con rsync y progress
function transferToRsync(localPath, fileName, sessionId) {
  return new Promise((resolve, reject) => {
    const rsyncCommand = `rsync -avz --progress --stats --partial --port=${rsyncConfig.port} --password-file="${rsyncConfig.passwordFile}" "${localPath}" ${rsyncConfig.user}@${rsyncConfig.host}::${rsyncConfig.module}/`;

    emitProgress(
      sessionId,
      "rsync_start",
      `Transfiriendo ${fileName} al servidor remoto`
    );
    console.log("Ejecutando rsync...");
    console.log(
      `Transferencia: ${fileName} -> ${rsyncConfig.host}::${rsyncConfig.module}`
    );

    const rsyncProcess = exec(
      rsyncCommand,
      { timeout: 600000 },
      (error, stdout, stderr) => {
        if (error) {
          emitProgress(
            sessionId,
            "rsync_error",
            `Error en transferencia: ${error.message}`
          );
          reject(new Error(`Error rsync: ${error.message}`));
          return;
        }

        if (stderr && !stderr.includes("speedup is")) {
          console.warn("Advertencia rsync:", stderr);
          emitProgress(sessionId, "rsync_warning", `Advertencia: ${stderr}`);
        }

        emitProgress(
          sessionId,
          "rsync_complete",
          "Transferencia rsync completada exitosamente"
        );
        console.log("Rsync completado exitosamente");
        resolve(stdout);
      }
    );

    // Opcional: Monitorear progress del proceso rsync
    rsyncProcess.stdout?.on("data", (data) => {
      const output = data.toString();
      if (output.includes("%")) {
        // Extraer porcentaje si está disponible
        const progressMatch = output.match(/(\d+)%/);
        if (progressMatch) {
          const percent = parseInt(progressMatch[1]);
          emitProgress(
            sessionId,
            "rsync_progress",
            `Transfiriendo: ${percent}%`,
            60 + percent * 0.3
          );
        }
      }
    });
  });
}

// ============ ENDPOINTS DE ESTADO ============

app.get("/databases", (req, res) => {
  res.json({
    databases: availableDatabases,
    server: `${sqlConfig.server}:${sqlConfig.port}`,
    count: availableDatabases.length,
  });
});

app.get("/test-connection", async (req, res) => {
  try {
    const pool = await sql.connect(sqlConfig);
    const result = await pool
      .request()
      .query(
        "SELECT @@VERSION as version, @@SERVERNAME as server, GETDATE() as fecha_actual"
      );
    await pool.close();

    res.json({
      success: true,
      connection: "OK",
      serverInfo: result.recordset[0],
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error("Error de conexión SQL:", error.message);
    res.status(500).json({
      success: false,
      error: "Error de conexión a SQL Server",
      details: error.message,
    });
  }
});

async function checkRsyncAvailability() {
  return new Promise((resolve) => {
    exec("rsync --version", { timeout: 5000 }, (error, stdout, stderr) => {
      if (error) {
        console.error("Rsync check error:", { error, stdout, stderr });
      }
      resolve(!error);
    });
  });
}

app.get("/test-rsync", async (req, res) => {
  try {
    const rsyncAvailable = await checkRsyncAvailability();
    if (!rsyncAvailable) {
      return res.status(500).json({
        success: false,
        error: "rsync no está disponible",
        details: "Instalar rsync es requerido",
        platform: process.platform,
      });
    }

    const portAvailable = await new Promise((resolve) => {
      const socket = new net.Socket();
      socket.setTimeout(5000);
      socket.on("connect", () => {
        socket.destroy();
        resolve(true);
      });
      socket.on("timeout", () => {
        socket.destroy();
        resolve(false);
      });
      socket.on("error", () => {
        resolve(false);
      });
      socket.connect(rsyncConfig.port, rsyncConfig.host);
    });

    if (!portAvailable) {
      return res.status(500).json({
        success: false,
        error: "No se puede conectar al puerto del servidor",
        details: `El puerto ${rsyncConfig.port} en ${rsyncConfig.host} no está accesible`,
      });
    }

    // Crear archivo temporal de contraseña en el directorio del proyecto
    const projectTempDir = path.join(process.cwd(), "temp");
    await fsPromises.mkdir(projectTempDir, { recursive: true });

    const tempPasswordFile = path.join(
      projectTempDir,
      `rsync_temp_${Date.now()}.pwd`
    );
    await fsPromises.writeFile(tempPasswordFile, rsyncConfig.passwordFile);

    if (process.platform !== "win32") {
      await fsPromises.chmod(tempPasswordFile, 0o600);
    }

    const testCommand = `rsync --port=${rsyncConfig.port} --password-file="${tempPasswordFile}" ${rsyncConfig.user}@${rsyncConfig.host}::${rsyncConfig.module}/`;

    console.log("Probando conexión rsync...");

    exec(testCommand, { timeout: 30000 }, async (error, stdout, stderr) => {
      try {
        await fsPromises.unlink(tempPasswordFile);
      } catch (cleanupError) {
        console.warn("Error limpiando archivo temporal:", cleanupError);
      }

      if (error) {
        return res.status(500).json({
          success: false,
          error: "Error en comunicación rsync",
          details: stderr || error.message,
        });
      }

      res.json({
        success: true,
        connection: "OK",
        server: `${rsyncConfig.host}:${rsyncConfig.port}`,
        module: rsyncConfig.module,
        moduleContent: stdout || "Módulo accesible",
        timestamp: new Date().toISOString(),
      });
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: "Error interno del servidor",
      details: error.message,
    });
  }
});

// ============ ENDPOINTS EXISTENTES MODIFICADOS ============

// Modificar el endpoint /status para incluir información de Oracle
const originalStatusHandler = app._router.stack.find(
  (layer) => layer.route && layer.route.path === "/status"
)?.route.stack[0].handle;

if (originalStatusHandler) {
}
app.get("/status", async (req, res) => {
  try {
    // Obtener status original
    const originalStatus = {
      status: "running",
      timestamp: new Date().toISOString(),
      config: {
        databases: availableDatabases,
        sqlServer: `${sqlConfig.server}:${sqlConfig.port}`,
        rsyncServer: `${rsyncConfig.host}:${rsyncConfig.port}`,
        tempDir: tempDir,
      },
    };

    // Añadir información de Oracle
    let oracleStatus = "❌ No disponible";
    try {
      const isOracleConnected = await testOracleConnection();
      oracleStatus = isOracleConnected ? "✅ Conectado" : "❌ Error";
    } catch (error) {
      oracleStatus = "❌ Error";
    }

    res.json({
      ...originalStatus,
      config: {
        ...originalStatus.config,
        oracleServer: oracleConfig.connectString,
        oracleStatus,
      },
      endpoints: [
        "GET  /status",
        "GET  /databases",
        "GET  /test-connection",
        "GET  /test-rsync",
        "GET  /test-oracle",
        "GET  /sync/preview",
        "POST /sync/execute",
        "GET  /progress/:sessionId",
        "POST /backup/:database",
        "POST /backup/all",
      ],
    });
  } catch (error) {
    res.status(500).json({
      success: false,
      error: "Error obteniendo status",
      details: error.message,
    });
  }
});

// ============ CÓDIGO A AÑADIR AL server.js ============
// Añadir después de las importaciones existentes

import {
  executeQuery as executeOracleQuery,
  testConnection as testOracleConnection,
  defaultConfig as oracleConfig,
} from "./database.oracle.js";

// ============ ENDPOINTS PARA SINCRONIZACIÓN ORACLE ============

// Preview de sincronización - mostrar qué se va a sincronizar
app.get("/sync/preview", async (req, res) => {
  try {
    emitProgress = emitProgress || function () {}; // Fallback si no está definido
    const sessionId = `sync_preview_${Date.now()}`;

    console.log("Iniciando preview de sincronización...");

    // 1. Obtener datos de Oracle
    console.log("Conectando a Oracle...");
    const oracleData = await executeOracleQuery(`
      SELECT 
        codigo_empleado, 
        nombre_empleado, 
        cedula_empleado, 
        cargo, 
        regimen, 
        departamento,
        estado_empleado 
      FROM v_empleados 
      WHERE codigo_empleado IS NOT NULL AND estado_empleado = 1
      ORDER BY codigo_empleado
    `);

    console.log(`Registros encontrados en Oracle: ${oracleData.rows.length}`);

    // 2. Obtener datos de SQL Server
    console.log("Conectando a SQL Server...");
    let pool;
    let sqlData;
    try {
      pool = await sql.connect(sqlConfig);
      const result = await pool.request().query(`
        SELECT 
          codigo_empleado,
          nombres,
          identificacion,
          regimen,
          cargo,
          depertamento as departamento
        FROM biometricos.dbo.datos_funcionario
        WHERE codigo_empleado IS NOT NULL
        ORDER BY codigo_empleado
      `);
      //SELECT * FROM v_marcaciones WHERE fecha BETWEEN '2025-07-01' AND '2025-07-11' ORDER BY funcionario, creacion
      sqlData = result.recordset;
      console.log(`Registros encontrados en SQL Server: ${sqlData.length}`);
    } finally {
      if (pool) await pool.close();
    }

    // 3. Análisis de diferencias
    const analysis = analyzeDataDifferences(oracleData.rows, sqlData);

    res.json({
      success: true,
      sessionId,
      summary: {
        oracleRecords: oracleData.rows.length,
        sqlRecords: sqlData.length,
        newRecords: analysis.newRecords.length,
        existingRecords: analysis.existingRecords.length,
        conflictingRecords: analysis.conflictingRecords.length,
        sqlOnlyRecords: analysis.sqlOnlyRecords.length,
      },
      details: {
        newRecords: analysis.newRecords.slice(0, 10), // Primeros 10 para preview
        conflictingRecords: analysis.conflictingRecords.slice(0, 10),
        sqlOnlyRecords: analysis.sqlOnlyRecords.slice(0, 10),
      },
      timestamp: new Date().toISOString(),
    });
  } catch (error) {
    console.error("Error en preview de sincronización:", error);
    res.status(500).json({
      success: false,
      error: "Error obteniendo preview de sincronización",
      details: error.message,
    });
  }
});

// Ejecutar sincronización con confirmación
// Ejecutar sincronización con confirmación
app.post("/sync/execute", async (req, res) => {
  const { confirmed, doubleConfirmed } = req.body;
  const sessionId = `sync_execute_${Date.now()}`;

  // Validar doble confirmación
  if (!confirmed || !doubleConfirmed) {
    return res.status(400).json({
      success: false,
      error: "Se requiere doble confirmación para ejecutar la sincronización",
    });
  }

  try {
    // Enviar respuesta inmediata
    res.json({
      success: true,
      message: "Sincronización iniciada",
      sessionId,
      progressUrl: `/progress/${sessionId}`,
    });

    emitProgress(
      sessionId,
      "init",
      "Iniciando sincronización Oracle → SQL Server"
    );

    // 1. Obtener datos de Oracle
    emitProgress(sessionId, "oracle_fetch", "Obteniendo datos de Oracle", 10);
    const oracleData = await executeOracleQuery(`
      SELECT 
        codigo_empleado, 
        nombre_empleado, 
        cedula_empleado, 
        cargo, 
        regimen, 
        departamento,
        estado_empleado 
      FROM v_empleados 
      WHERE codigo_empleado IS NOT NULL AND estado_empleado = 1
      ORDER BY codigo_empleado
    `);

    emitProgress(
      sessionId,
      "oracle_complete",
      `${oracleData.rows.length} registros obtenidos de Oracle`,
      25
    );

    // 2. Obtener datos existentes de SQL Server
    emitProgress(
      sessionId,
      "sql_fetch",
      "Obteniendo datos existentes de SQL Server",
      35
    );
    let pool;
    let existingSqlData;
    try {
      pool = await sql.connect(sqlConfig);
      const result = await pool.request().query(`
        SELECT codigo_empleado, nombres, identificacion, regimen, cargo, depertamento
        FROM biometricos.dbo.datos_funcionario
        WHERE codigo_empleado IS NOT NULL
      `);
      existingSqlData = result.recordset;
    } finally {
      if (pool) await pool.close();
    }

    emitProgress(
      sessionId,
      "sql_complete",
      `${existingSqlData.length} registros existentes en SQL Server`,
      45
    );

    // 3. Analizar diferencias
    emitProgress(sessionId, "analysis", "Analizando diferencias", 55);
    const analysis = analyzeDataDifferences(oracleData.rows, existingSqlData);

    emitProgress(
      sessionId,
      "analysis_complete",
      `Análisis completo: ${analysis.newRecords.length} nuevos, ${analysis.conflictingRecords.length} conflictos`,
      65
    );

    // 4. Ejecutar sincronización
    emitProgress(
      sessionId,
      "sync_start",
      "Iniciando inserción de registros",
      70
    );

    let insertedCount = 0;
    let updatedCount = 0;
    let errorCount = 0;
    let skippedCount = 0;

    pool = await sql.connect(sqlConfig);

    try {
      // Insertar registros nuevos
      for (let i = 0; i < analysis.newRecords.length; i++) {
        const record = analysis.newRecords[i];

        // Validar y convertir el código de empleado
        const codigoEmpleado =
          record.CODIGO_EMPLEADO != null
            ? String(record.CODIGO_EMPLEADO).trim()
            : null;

        // Saltar registros con código inválido
        if (!codigoEmpleado || codigoEmpleado === "") {
          console.warn(
            `Saltando registro con código de empleado inválido:`,
            record
          );
          skippedCount++;
          continue;
        }

        try {
          await pool
            .request()
            .input("codigo_empleado", sql.VarChar, codigoEmpleado)
            .input(
              "nombres",
              sql.VarChar,
              record.NOMBRE_EMPLEADO
                ? String(record.NOMBRE_EMPLEADO).trim()
                : null
            )
            .input(
              "identificacion",
              sql.VarChar,
              record.CEDULA_EMPLEADO
                ? String(record.CEDULA_EMPLEADO).trim()
                : null
            )
            .input(
              "regimen",
              sql.VarChar,
              record.REGIMEN ? String(record.REGIMEN).trim() : null
            )
            .input(
              "cargo",
              sql.VarChar,
              record.CARGO ? String(record.CARGO).trim() : null
            )
            .input(
              "departamento",
              sql.VarChar,
              record.DEPARTAMENTO ? String(record.DEPARTAMENTO).trim() : null
            ).query(`
              INSERT INTO biometricos.dbo.datos_funcionario 
              (codigo_empleado, nombres, identificacion, regimen, cargo, depertamento)
              VALUES (@codigo_empleado, @nombres, @identificacion, @regimen, @cargo, @departamento)
            `);
          insertedCount++;

          if (i % 10 === 0) {
            const progress = 70 + (i / analysis.newRecords.length) * 20;
            emitProgress(
              sessionId,
              "inserting",
              `Insertando registros: ${i + 1}/${analysis.newRecords.length}`,
              progress
            );
          }
        } catch (insertError) {
          console.error(
            `Error insertando registro ${codigoEmpleado}:`,
            insertError.message || insertError
          );
          errorCount++;
        }
      }

      // Actualizar registros conflictivos
      for (let i = 0; i < analysis.conflictingRecords.length; i++) {
        const record = analysis.conflictingRecords[i];

        // Validar y convertir el código de empleado
        const codigoEmpleado =
          record.oracle.CODIGO_EMPLEADO != null
            ? String(record.oracle.CODIGO_EMPLEADO).trim()
            : null;

        // Saltar registros con código inválido
        if (!codigoEmpleado || codigoEmpleado === "") {
          console.warn(
            `Saltando actualización con código de empleado inválido:`,
            record.oracle
          );
          skippedCount++;
          continue;
        }

        try {
          await pool
            .request()
            .input("codigo_empleado", sql.VarChar, codigoEmpleado)
            .input(
              "nombres",
              sql.VarChar,
              record.oracle.NOMBRE_EMPLEADO
                ? String(record.oracle.NOMBRE_EMPLEADO).trim()
                : null
            )
            .input(
              "identificacion",
              sql.VarChar,
              record.oracle.CEDULA_EMPLEADO
                ? String(record.oracle.CEDULA_EMPLEADO).trim()
                : null
            )
            .input(
              "regimen",
              sql.VarChar,
              record.oracle.REGIMEN
                ? String(record.oracle.REGIMEN).trim()
                : null
            )
            .input(
              "cargo",
              sql.VarChar,
              record.oracle.CARGO ? String(record.oracle.CARGO).trim() : null
            )
            .input(
              "departamento",
              sql.VarChar,
              record.oracle.DEPARTAMENTO
                ? String(record.oracle.DEPARTAMENTO).trim()
                : null
            ).query(`
              UPDATE biometricos.dbo.datos_funcionario 
              SET nombres = @nombres,
                  identificacion = @identificacion,
                  regimen = @regimen,
                  cargo = @cargo,
                  depertamento = @departamento
              WHERE codigo_empleado = @codigo_empleado
            `);
          updatedCount++;
        } catch (updateError) {
          console.error(
            `Error actualizando registro ${codigoEmpleado}:`,
            updateError.message || updateError
          );
          errorCount++;
        }
      }
    } finally {
      await pool.close();
    }

    emitProgress(
      sessionId,
      "sync_complete",
      `Sincronización completada: ${insertedCount} insertados, ${updatedCount} actualizados, ${errorCount} errores, ${skippedCount} omitidos`,
      95
    );

    emitProgress(
      sessionId,
      "success",
      `Proceso completado exitosamente. Total procesados: ${
        insertedCount + updatedCount
      }`,
      100
    );
  } catch (error) {
    console.error("Error en sincronización:", error);
    emitProgress(
      sessionId,
      "error",
      `Error en sincronización: ${error.message}`
    );
  }
});

// Función auxiliar para analizar diferencias
function analyzeDataDifferences(oracleRecords, sqlRecords) {
  const sqlMap = new Map();
  sqlRecords.forEach((record) => {
    sqlMap.set(record.codigo_empleado, record);
  });

  const newRecords = [];
  const existingRecords = [];
  const conflictingRecords = [];

  oracleRecords.forEach((oracleRecord) => {
    const sqlRecord = sqlMap.get(oracleRecord.CODIGO_EMPLEADO);

    if (!sqlRecord) {
      // Registro nuevo en Oracle
      newRecords.push(oracleRecord);
    } else {
      // Registro existente - verificar si hay diferencias
      const hasConflicts =
        sqlRecord.nombres !== oracleRecord.NOMBRE_EMPLEADO ||
        sqlRecord.identificacion !== oracleRecord.CEDULA_EMPLEADO ||
        sqlRecord.regimen !== oracleRecord.REGIMEN ||
        sqlRecord.cargo !== oracleRecord.CARGO ||
        sqlRecord.departamento !== oracleRecord.DEPARTAMENTO;

      if (hasConflicts) {
        conflictingRecords.push({
          oracle: oracleRecord,
          sql: sqlRecord,
          differences: {
            nombres: sqlRecord.nombres !== oracleRecord.NOMBRE_EMPLEADO,
            identificacion:
              sqlRecord.identificacion !== oracleRecord.CEDULA_EMPLEADO,
            regimen: sqlRecord.regimen !== oracleRecord.REGIMEN,
            cargo: sqlRecord.cargo !== oracleRecord.CARGO,
            departamento: sqlRecord.departamento !== oracleRecord.DEPARTAMENTO,
          },
        });
      } else {
        existingRecords.push(oracleRecord);
      }
    }
  });

  // Registros que solo existen en SQL
  const oracleCodesSet = new Set(oracleRecords.map((r) => r.CODIGO_EMPLEADO));
  const sqlOnlyRecords = sqlRecords.filter(
    (sqlRecord) => !oracleCodesSet.has(sqlRecord.codigo_empleado)
  );

  return {
    newRecords,
    existingRecords,
    conflictingRecords,
    sqlOnlyRecords,
  };
}

// Test de conexión Oracle
app.get("/test-oracle", async (req, res) => {
  try {
    console.log("Probando conexión a Oracle...");
    const isConnected = await testOracleConnection();

    if (isConnected) {
      // Obtener información adicional
      const result = await executeOracleQuery(
        "SELECT COUNT(*) as total FROM v_empleados WHERE estado_empleado = 1"
      );
      const totalEmpleados = result.rows[0]?.TOTAL || 0;

      res.json({
        success: true,
        connection: "OK",
        server: oracleConfig.connectString,
        user: oracleConfig.user,
        totalEmpleados,
        timestamp: new Date().toISOString(),
      });
    } else {
      res.status(500).json({
        success: false,
        error: "No se pudo conectar a Oracle",
        server: oracleConfig.connectString,
      });
    }
  } catch (error) {
    console.error("Error probando conexión Oracle:", error);
    res.status(500).json({
      success: false,
      error: "Error de conexión a Oracle",
      details: error.message,
    });
  }
});

// ============ MANEJO DE ERRORES ============

app.use((error, req, res, next) => {
  console.error("Error no manejado:", error);
  res.status(500).json({
    success: false,
    error: "Error interno del servidor",
    timestamp: new Date().toISOString(),
  });
});

// MIDDLEWARE 404 - DEBE IR AL FINAL
app.use("*", (req, res) => {
  console.log(`❌ Ruta no encontrada: ${req.method} ${req.originalUrl}`);
  res.status(404).json({
    success: false,
    error: "Endpoint no encontrado",
    path: req.originalUrl,
  });
});

const PORT = process.env.PORT || 3000;

app.listen(PORT, () => {
  console.log("🚀 Servidor de backups ejecutándose");
  console.log(`📡 Puerto: ${PORT}`);
  console.log(`🌐 Interfaz web: http://localhost:${PORT}`);
  console.log(`📊 Bases de datos: ${availableDatabases.join(", ")}`);
  console.log(`🗄️  SQL Server: ${sqlConfig.server}:${sqlConfig.port}`);
  console.log(`📤 Rsync Server: ${rsyncConfig.host}:${rsyncConfig.port}`);
  console.log(`📁 Directorio temporal: ${tempDir}`);
  console.log(`📁 Directorio del servidor: ${__dirname}`);
  console.log("\n📋 Endpoints API disponibles:");
  console.log(`   GET  http://localhost:${PORT}/status`);
  console.log(`   GET  http://localhost:${PORT}/databases`);
  console.log(`   GET  http://localhost:${PORT}/test-connection`);
  console.log(`   GET  http://localhost:${PORT}/test-rsync`);
  console.log(`   GET  http://localhost:${PORT}/progress/:sessionId`);
  console.log(`   POST http://localhost:${PORT}/backup/:database`);
  console.log(`   POST http://localhost:${PORT}/backup/all`);
  console.log("\n🔒 Configuración cargada desde variables de entorno");
  console.log(
    "💡 Abre tu navegador en http://localhost:" +
      PORT +
      " para usar la interfaz web"
  );

  // Verificar si el archivo HTML existe al inicio
  const htmlPath = path.join(__dirname, "backup_client.html");
  if (fs.existsSync(htmlPath)) {
    console.log("✅ Archivo de interfaz web encontrado");
  } else {
    console.log("⚠️ Archivo de interfaz web NO encontrado en:", htmlPath);
    console.log("📁 Archivos disponibles en el directorio:");
    fs.readdirSync(__dirname).forEach((file) => {
      console.log(`   - ${file}`);
    });
  }
});

process.on("SIGINT", () => {
  console.log("\n🛑 Cerrando servidor...");
  process.exit(0);
});

process.on("SIGTERM", () => {
  console.log("\n🛑 Cerrando servidor...");
  process.exit(0);
});
