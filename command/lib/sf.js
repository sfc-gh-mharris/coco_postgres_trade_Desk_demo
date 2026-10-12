// Snowflake access from SPCS using the service's OAuth session token.
// SPCS injects SNOWFLAKE_ACCOUNT, SNOWFLAKE_HOST and /snowflake/session/token into every container.
// The token rotates, so it is re-read for each new connection; a connection is reused until it fails.
const fs = require('fs');
const snowflake = require('snowflake-sdk');

snowflake.configure({ logLevel: 'WARN' });
const TOKEN_PATH = '/snowflake/session/token';
let conn = null;

function connect() {
  return new Promise((resolve, reject) => {
    const c = snowflake.createConnection({
      account: process.env.SNOWFLAKE_ACCOUNT,
      accessUrl: `https://${process.env.SNOWFLAKE_HOST}`,
      authenticator: 'OAUTH',
      token: fs.readFileSync(TOKEN_PATH, 'utf8').trim(),
      warehouse: process.env.SNOWFLAKE_WAREHOUSE || 'DESK_WH',
      database: process.env.MIRROR_DB,
      schema: 'DESK',
      application: 'desk_command',
    });
    c.connect((err) => (err ? reject(err) : resolve(c)));
  });
}

async function getConn() {
  if (conn && conn.isUp()) return conn;
  conn = await connect();
  return conn;
}

function run(c, sqlText, binds) {
  return new Promise((resolve, reject) => {
    c.execute({
      sqlText, binds,
      complete: (err, _stmt, rows) => (err ? reject(err) : resolve(rows || [])),
    });
  });
}

async function query(sqlText, binds = []) {
  try {
    return await run(await getConn(), sqlText, binds);
  } catch (e) {
    // Expired token or dropped session: reconnect once with a fresh token.
    if (/token|session|authenticat|390114|390318|not connected/i.test(e.message || '')) {
      conn = null;
      return run(await getConn(), sqlText, binds);
    }
    throw e;
  }
}

module.exports = { query };
