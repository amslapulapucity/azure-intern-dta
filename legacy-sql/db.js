const fs = require("fs");
const path = require("path");
const sql = require("mssql");

let poolPromise = null;
let schemaPromise = null;

function getPool() {
  if (!process.env.SQL_CONNECTION_STRING) {
    return Promise.reject(new Error("SQL_CONNECTION_STRING application setting is missing"));
  }
  if (!poolPromise) {
    poolPromise = sql.connect(process.env.SQL_CONNECTION_STRING).catch((e) => {
      poolPromise = null;
      throw e;
    });
  }
  return poolPromise;
}

// Runs once per warm instance. Serverless databases wake on this call,
// so the first request after an idle period can take up to a minute.
function ensureSchema(pool) {
  if (!schemaPromise) {
    const ddl = fs.readFileSync(path.join(__dirname, "schema.sql"), "utf8");
    schemaPromise = pool
      .request()
      .batch(ddl)
      .catch((e) => {
        schemaPromise = null;
        throw e;
      });
  }
  return schemaPromise;
}

module.exports = { sql, getPool, ensureSchema };
