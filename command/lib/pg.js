// Postgres access for the command center.
// Two logins, each limited to its job by the desk schema grants:
//   approver: desk_approver_svc  -> approve_action, set_agent_control, close_desk_day, console views
//   sim:      desk_sim           -> insert_break only
const fs = require('fs');
const { Pool, Client } = require('pg');

const PG_HOST = process.env.PGHOST;
const CA_PATH = process.env.PG_CA || '/secrets/pg_ca/secret_string';

function creds(dir) {
  const read = (f) => fs.readFileSync(`${dir}/${f}`, 'utf8').trim();
  return { user: read('username'), password: read('password') };
}

function baseConfig(dir, appName) {
  return {
    host: PG_HOST, port: 5432, database: 'postgres', ...creds(dir),
    ssl: { ca: fs.readFileSync(CA_PATH, 'utf8'), rejectUnauthorized: true, servername: PG_HOST },
    application_name: appName, connectionTimeoutMillis: 15000,
  };
}

const approver = new Pool({ ...baseConfig('/secrets/pg_approver', 'desk_command'), max: 6 });
const sim = new Pool({ ...baseConfig('/secrets/pg_sim', 'desk_command_sim'), max: 2 });
for (const p of [approver, sim]) p.on('error', (e) => console.error('pg pool error', e.message));

const CHANNELS = ['breaks_new', 'qc_pending', 'actions_approved', 'agent_controls', 'desk_day'];

// Dedicated LISTEN connection; reconnects with backoff. onNotify(channel, payload).
function listen(onNotify, onState) {
  let delay = 1000;
  const connect = async () => {
    const client = new Client(baseConfig('/secrets/pg_approver', 'desk_command_listen'));
    client.on('notification', (n) => onNotify(n.channel, n.payload));
    client.on('error', (e) => console.error('listen error', e.message));
    client.on('end', () => { onState(false); setTimeout(connect, delay); delay = Math.min(delay * 2, 30000); });
    try {
      await client.connect();
      for (const c of CHANNELS) await client.query(`LISTEN ${c}`);
      delay = 1000;
      onState(true);
      console.log('LISTEN', CHANNELS.join(','));
    } catch (e) {
      console.error('listen connect failed', e.message);
      client.end().catch(() => {});
    }
  };
  connect();
}

module.exports = { approver, sim, listen };
