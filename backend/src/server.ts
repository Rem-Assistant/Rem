import './crypto-polyfill.js'; // MUST be first — installs globalThis.crypto before Composio SDK loads
import express from 'express';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import fs from 'node:fs';
import gatewayRoutes from './routes/gateway.routes.js';
import tasksRoutes from './routes/tasks.routes.js';
import digestsRoutes from './routes/digests.routes.js';
import briefRoutes from './routes/brief.routes.js';
import routinesRoutes from './routes/routines.routes.js';
import internalRoutinesRoutes from './routes/internal-routines.routes.js';
import authRoutes from './routes/auth.routes.js';
import pushRoutes from './routes/push.routes.js';
import userMemoryRoutes from './routes/user-memory.routes.js';
import composioRoutes from './routes/composio.routes.js';
import checkinRoutes from './routes/checkin.routes.js';
import organizationRoutes from './routes/organization.routes.js';
import suggestionsRoutes from './routes/suggestions.routes.js';
import automationsRoutes from './routes/automations.routes.js';
import usersRoutes from './routes/users.routes.js';
import { pool } from './db/pool.js';
import { env } from './config/env.js';
import { extractClientInfo } from './middleware/client-info.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const migrationsDir = path.join(__dirname, 'db', 'migrations');

async function runMigrations(retries = 10, delayMs = 3000) {
  const files = fs.readdirSync(migrationsDir).filter((f) => f.endsWith('.sql')).sort();
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      const client = await pool.connect();
      try {
        for (const file of files) {
          const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
          await client.query('BEGIN');
          try {
            await client.query(sql);
            await client.query('COMMIT');
          } catch (migrationError) {
            await client.query('ROLLBACK');
            throw migrationError;
          }
        }
        console.log('Migrations complete');
        return;
      } finally {
        client.release();
      }
    } catch (err) {
      console.error(`[Migration] Attempt ${attempt}/${retries} failed:`, (err as Error).message);
      if (attempt === retries) throw err;
      await new Promise((r) => setTimeout(r, delayMs));
    }
  }
}

const app = express();
app.use(express.json());

app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - start;
    const userId = (req as any).userId ?? '-';
    const client = extractClientInfo(req);
    console.log(`[${new Date().toISOString()}] ${req.method} ${req.path} ${res.statusCode} ${ms}ms userId=${userId} clientVersion=${client.version} clientPlatform=${client.platform}`);
  });
  next();
});

app.get('/health', (_req, res) => res.json({ ok: true }));

app.use('/api/v1/auth', authRoutes);
app.use('/api/v1', gatewayRoutes);
app.use('/api/v1', tasksRoutes);
app.use('/api/v1', digestsRoutes);
app.use('/api/v1', briefRoutes);
app.use('/api/v1', routinesRoutes);
// Internal routine-run webhook (shared-secret auth — NOT requireJwt). Path is
// /api/v1/internal/routines/:id/run. No longer the scheduled path (scheduling moved to
// the backend cron script run-routines.ts); kept as a manual/programmatic trigger seam.
app.use('/api/v1', internalRoutinesRoutes);
app.use('/api/v1', pushRoutes);
app.use('/api/v1', userMemoryRoutes);
app.use('/api/v1', composioRoutes);
app.use('/api/v1', checkinRoutes);
app.use('/api/v1', organizationRoutes);
app.use('/api/v1', suggestionsRoutes);
app.use('/api/v1', automationsRoutes);
app.use('/api/v1', usersRoutes);

const PORT = Number.parseInt(process.env.PORT ?? '3000', 10);

async function start() {
  // A partially migrated schema is not safe to serve. Push destination ownership in particular is
  // a privacy boundary, so finish migrations before accepting registration or delivery traffic.
  await runMigrations();
  app.listen(PORT, () => {
    console.log('Listening on', PORT);
  });
}

start().catch((err) => {
  console.error(err);
});
