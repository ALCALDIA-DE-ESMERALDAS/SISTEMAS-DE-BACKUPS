import oracledb from "oracledb";
import crypto from "crypto";

// CONFIGURAR MODO THICK PARA ORACLE 10G con la ruta correcta
try {
  oracledb.initOracleClient({
    libDir: "E:/DRIVERS/instantclient_23_8", // Ruta actualizada según especificación del usuario
  });
  console.log(
    "✅ Oracle Client inicializado exitosamente desde E:/DRIVERS/instantclient_23_8"
  );
} catch (err) {
  console.error("❌ Error inicializando Oracle Client:", err.message);
  console.error(
    "💡 Verifica que la ruta E:/DRIVERS/instantclient_23_8 exista y contenga los archivos Oracle Client"
  );
}

// Pool de conexiones por usuario con hash de credenciales
const userPools = new Map();

// Configuración de conexión por defecto (para Oracle 10g usar SID o SERVICE_NAME)
const defaultConfig = {
  user: process.env.ORACLE_DEFAULT_USER || "CAMALGAD",
  password: process.env.ORACLE_DEFAULT_PASSWORD || "CAM/2025*Gadmce",
  connectString:
    process.env.ORACLE_DEFAULT_CONNECT_STRING || "192.168.120.13:1521/bdesme", // Para Oracle 10g
};

const defaultPoolConfig = {
  ...defaultConfig,
  poolMin: 2,
  poolMax: 10,
  poolIncrement: 2,
  poolTimeout: 300,
  stmtCacheSize: 23,
};

let defaultPool;

/**
 * Genera un hash único para las credenciales
 * @param {object} credentials - Credenciales de conexión
 * @returns {string} Hash único
 */
function generateCredentialsHash(credentials) {
  const data = `${credentials.user}:${credentials.password}:${credentials.connectString}`;
  return crypto.createHash("sha256").update(data).digest("hex");
}

/**
 * Obtiene la clave del pool basada en las credenciales
 * @param {object} credentials - Credenciales de conexión
 * @returns {string} Clave única para el pool
 */
function getPoolKey(credentials) {
  return `${credentials.user}_${generateCredentialsHash(credentials)}`;
}

// Inicializar el pool por defecto
async function initializeDefaultPool() {
  try {
    console.log("🔄 Inicializando pool Oracle por defecto...");
    console.log(`📡 Conectando a: ${defaultConfig.connectString}`);
    console.log(`👤 Usuario: ${defaultConfig.user}`);

    defaultPool = await oracledb.createPool(defaultPoolConfig);
    console.log("✅ Pool Oracle por defecto creado exitosamente");
    return defaultPool;
  } catch (error) {
    console.error("❌ Error al crear el pool Oracle por defecto:", error);
    console.error("💡 Verifique:");
    console.error(
      "   - Que Oracle Client esté instalado en E:/DRIVERS/instantclient_23_8"
    );
    console.error(
      "   - Que el servidor Oracle esté accesible en",
      defaultConfig.connectString
    );
    console.error("   - Que las credenciales sean correctas");
    throw error;
  }
}

// Inicializar un pool para un usuario específico
async function initializeUserPool(credentials) {
  try {
    console.log("🔄 Inicializando pool Oracle para usuario...", {
      user: credentials.user,
      connectString: credentials.connectString,
    });

    const poolConfig = {
      user: credentials.user,
      password: credentials.password,
      connectString: credentials.connectString,
      poolMin: 2,
      poolMax: 5,
      poolIncrement: 1,
      poolTimeout: 300,
      stmtCacheSize: 10,
    };

    const pool = await oracledb.createPool(poolConfig);
    const poolKey = getPoolKey(credentials);
    userPools.set(poolKey, {
      pool,
      credentials: { ...credentials },
      createdAt: new Date(),
    });

    console.log(
      `✅ Pool Oracle creado para usuario ${
        credentials.user
      } con clave ${poolKey.substring(0, 20)}...`
    );
    return pool;
  } catch (error) {
    console.error(
      `❌ Error al crear pool Oracle para usuario ${credentials.user}:`,
      error
    );
    throw error;
  }
}

/**
 * Cierra y remueve un pool específico
 * @param {string} poolKey - Clave del pool a cerrar
 */
async function closeUserPool(poolKey) {
  try {
    const poolData = userPools.get(poolKey);
    if (poolData) {
      await poolData.pool.close(5);
      userPools.delete(poolKey);
      console.log(
        `✅ Pool Oracle cerrado y removido: ${poolKey.substring(0, 20)}...`
      );
    }
  } catch (error) {
    console.error(`❌ Error cerrando pool Oracle ${poolKey}:`, error);
  }
}

/**
 * Limpia pools antiguos (más de 1 hora)
 */
async function cleanupOldPools() {
  const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);

  for (const [poolKey, poolData] of userPools.entries()) {
    if (poolData.createdAt < oneHourAgo) {
      console.log(
        `🧹 Limpiando pool Oracle antiguo: ${poolKey.substring(0, 20)}...`
      );
      await closeUserPool(poolKey);
    }
  }
}

// Obtener una conexión del pool adecuado
async function getConnection(credentials = null) {
  try {
    console.log(
      "🔄 Obteniendo conexión Oracle...",
      credentials
        ? { user: credentials.user, connectString: credentials.connectString }
        : "default"
    );

    if (credentials) {
      const poolKey = getPoolKey(credentials);
      let poolData = userPools.get(poolKey);

      // Si no existe el pool o las credenciales son diferentes, crear uno nuevo
      if (!poolData) {
        // Limpiar pools antiguos antes de crear uno nuevo
        await cleanupOldPools();

        // Buscar y cerrar pools del mismo usuario con credenciales diferentes
        for (const [existingKey, existingPoolData] of userPools.entries()) {
          if (
            existingPoolData.credentials.user === credentials.user &&
            existingKey !== poolKey
          ) {
            console.log(
              `🔄 Cerrando pool Oracle existente con credenciales diferentes para usuario ${credentials.user}`
            );
            await closeUserPool(existingKey);
          }
        }

        poolData = { pool: await initializeUserPool(credentials) };
      }

      const connection = await poolData.pool.getConnection();
      console.log(
        `✅ Conexión Oracle obtenida para usuario ${credentials.user}`
      );
      return connection;
    } else {
      if (!defaultPool) {
        await initializeDefaultPool();
      }
      const connection = await defaultPool.getConnection();
      console.log("✅ Conexión Oracle obtenida del pool por defecto");
      return connection;
    }
  } catch (error) {
    console.error("❌ Error al obtener conexión Oracle:", error);

    // Si hay error de autenticación, limpiar el pool problemático
    if (
      credentials &&
      (error.errorNum === 1017 ||
        error.message.includes("invalid username/password"))
    ) {
      const poolKey = getPoolKey(credentials);
      console.log(
        `🧹 Error de autenticación detectado, limpiando pool Oracle: ${poolKey.substring(
          0,
          20
        )}...`
      );
      await closeUserPool(poolKey);
    }

    throw error;
  }
}

// Cerrar todos los pools
async function closeAllPools() {
  try {
    console.log("🔄 Cerrando todos los pools Oracle...");

    // Cerrar pools de usuarios
    for (const [poolKey, poolData] of userPools.entries()) {
      try {
        await poolData.pool.close(5);
        console.log(
          `✅ Pool Oracle cerrado para clave ${poolKey.substring(0, 20)}...`
        );
      } catch (error) {
        console.error(`❌ Error cerrando pool Oracle ${poolKey}:`, error);
      }
    }
    userPools.clear();

    // Cerrar pool por defecto
    if (defaultPool) {
      await defaultPool.close(10);
      console.log("✅ Pool Oracle por defecto cerrado");
      defaultPool = undefined;
    }
  } catch (error) {
    console.error("❌ Error al cerrar pools Oracle:", error);
  }
}

// Función para ejecutar consultas con mejor manejo de errores
async function executeQuery(query, binds = [], credentials = null) {
  let connection;
  try {
    console.log(
      "🔄 Ejecutando consulta Oracle...",
      credentials
        ? { user: credentials.user, connectString: credentials.connectString }
        : "default"
    );
    console.log(
      "📝 Query:",
      query.substring(0, 100) + (query.length > 100 ? "..." : "")
    );

    connection = await getConnection(credentials);
    const result = await connection.execute(query, binds, {
      outFormat: oracledb.OUT_FORMAT_OBJECT,
      autoCommit: true,
    });

    console.log(
      `✅ Consulta Oracle ejecutada exitosamente. Registros: ${
        result.rows ? result.rows.length : 0
      }`
    );
    return result;
  } catch (error) {
    console.error("❌ Error ejecutando consulta Oracle:", error);
    console.error("📝 Query que falló:", query);
    throw error;
  } finally {
    if (connection) {
      try {
        await connection.close();
        console.log("✅ Conexión Oracle cerrada");
      } catch (error) {
        console.error("❌ Error cerrando conexión Oracle:", error);
      }
    }
  }
}

// Función para ejecutar transacciones
async function executeTransaction(queries, credentials = null) {
  let connection;
  try {
    console.log(
      `🔄 Ejecutando transacción Oracle con ${queries.length} queries...`
    );
    connection = await getConnection(credentials);

    for (const { query, binds } of queries) {
      await connection.execute(query, binds || []);
    }

    await connection.commit();
    console.log("✅ Transacción Oracle completada exitosamente");
    return { success: true };
  } catch (error) {
    console.error("❌ Error en transacción Oracle:", error);
    if (connection) {
      try {
        await connection.rollback();
        console.log("🔄 Transacción Oracle revertida");
      } catch (rollbackError) {
        console.error("❌ Error en rollback Oracle:", rollbackError);
      }
    }
    throw error;
  } finally {
    if (connection) {
      try {
        await connection.close();
      } catch (error) {
        console.error("❌ Error cerrando conexión Oracle:", error);
      }
    }
  }
}

// Función de prueba de conexión con diagnóstico mejorado
async function testConnection(credentials = null) {
  try {
    console.log(
      "🔄 Probando conexión Oracle...",
      credentials
        ? { user: credentials.user, connectString: credentials.connectString }
        : "default"
    );

    const result = await executeQuery(
      "SELECT SYSDATE, USER, SYS_CONTEXT('USERENV','DB_NAME') as DB_NAME FROM DUAL",
      [],
      credentials
    );

    if (result.rows && result.rows.length > 0) {
      const row = result.rows[0];
      console.log("✅ Conexión Oracle exitosa:");
      console.log(`   📅 Fecha del servidor: ${row.SYSDATE}`);
      console.log(`   👤 Usuario conectado: ${row.USER}`);
      console.log(`   🗄️ Base de datos: ${row.DB_NAME}`);
      return true;
    } else {
      console.log("⚠️ Conexión Oracle exitosa pero sin datos");
      return true;
    }
  } catch (error) {
    console.error("❌ Error en prueba de conexión Oracle:", error);
    return false;
  }
}

// Función para invalidar pools de un usuario específico
async function invalidateUserPools(username) {
  try {
    const poolsToClose = [];

    for (const [poolKey, poolData] of userPools.entries()) {
      if (poolData.credentials.user === username) {
        poolsToClose.push(poolKey);
      }
    }

    for (const poolKey of poolsToClose) {
      await closeUserPool(poolKey);
    }

    console.log(
      `✅ Invalidados ${poolsToClose.length} pools Oracle para usuario ${username}`
    );
  } catch (error) {
    console.error(
      `❌ Error invalidando pools Oracle para usuario ${username}:`,
      error
    );
  }
}

// Función específica para obtener datos de empleados (para la sincronización)
async function getEmpleadosData(credentials = null) {
  try {
    console.log("🔄 Obteniendo datos de empleados desde v_empleados...");

    const query = `
      SELECT 
        codigo_empleado, 
        nombre_empleado, 
        cedula_empleado, 
        cargo, 
        regimen, 
        departamento,
        estado_empleado, 
      FROM v_empleados 
      WHERE codigo_empleado IS NOT NULL AND estado_empleado = 1
        AND TRIM(codigo_empleado) != ''
      ORDER BY codigo_empleado
    `;

    const result = await executeQuery(query, [], credentials);
    console.log(
      `✅ Obtenidos ${result.rows.length} registros de empleados desde Oracle`
    );

    return result.rows;
  } catch (error) {
    console.error("❌ Error obteniendo datos de empleados de Oracle:", error);
    throw error;
  }
}

// Configuración para cerrar los pools al terminar la aplicación
process.on("SIGINT", async () => {
  console.log("🛑 Cerrando aplicación - limpiando pools Oracle...");
  await closeAllPools();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  console.log("🛑 Cerrando aplicación - limpiando pools Oracle...");
  await closeAllPools();
  process.exit(0);
});

// Limpiar pools antiguos cada 30 minutos
setInterval(cleanupOldPools, 30 * 60 * 1000);

// Mostrar configuración al inicio
console.log("🔧 Configuración Oracle:");
console.log(`   📡 Servidor: ${defaultConfig.connectString}`);
console.log(`   👤 Usuario: ${defaultConfig.user}`);
console.log(`   📁 Oracle Client: E:/DRIVERS/instantclient_23_8`);

export {
  initializeDefaultPool,
  getConnection,
  closeAllPools,
  executeQuery,
  executeTransaction,
  testConnection,
  invalidateUserPools,
  cleanupOldPools,
  getEmpleadosData,
  defaultConfig,
  defaultPoolConfig,
};
