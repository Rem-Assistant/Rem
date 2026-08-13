/**
 * Task organization (Sorted-style): Folders group Lists; Lists group Tasks.
 *
 * Foundation slice. The list is entirely **user-managed** in this first cut: the app
 * (and the AI via device commands) create/rename/delete Folders and Lists, and the
 * backend Postgres `folders` / `lists` tables are the source of truth — iOS and Mac
 * render the identical structure (same as tasks / user_memory).
 *
 * Mirrors user-memory.service.ts: a RETURNING column list, a `formatRow` mapper, and
 * thin functions that own the SQL. No ORM — raw parameterized queries scoped by user.
 *
 * Lifecycle (principle 2): create / list / rename / delete for both Folders and Lists,
 * plus assigning a List to a Folder (move) and recovering from a deleted parent:
 *   - deleting a Folder un-files its Lists (ON DELETE SET NULL) — Lists survive ungrouped.
 *   - deleting a List un-files its Tasks (ON DELETE SET NULL) — Tasks revert to inbox.
 */

import { pool } from '../db/pool.js';

export interface FolderRow {
  id: string;
  name: string;
  sort_order: number;
  created_at: string | null;
  updated_at: string | null;
}

export interface ListRow {
  id: string;
  name: string;
  folder_id: string | null;
  sort_order: number;
  created_at: string | null;
  updated_at: string | null;
}

/** Max length of a Folder/List name — keeps the sidebar scannable. */
export const ORG_NAME_MAX_LENGTH = 255;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const FOLDER_RETURNING = 'id, name, sort_order, created_at, updated_at';
export const LIST_RETURNING = 'id, name, folder_id, sort_order, created_at, updated_at';

export class OrganizationValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'OrganizationValidationError';
  }
}

export function formatFolder(row: any): FolderRow {
  return {
    id: row.id.toString(),
    name: row.name,
    sort_order: row.sort_order ?? 0,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
    updated_at: row.updated_at ? new Date(row.updated_at).toISOString() : null,
  };
}

export function formatList(row: any): ListRow {
  return {
    id: row.id.toString(),
    name: row.name,
    folder_id: row.folder_id ? row.folder_id.toString() : null,
    sort_order: row.sort_order ?? 0,
    created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
    updated_at: row.updated_at ? new Date(row.updated_at).toISOString() : null,
  };
}

/** Validate + normalize a Folder/List name. Returns the trimmed value or throws. */
export function normalizeName(raw: unknown): string {
  if (typeof raw !== 'string') {
    throw new OrganizationValidationError('name is required and must be a string');
  }
  const trimmed = raw.trim();
  if (trimmed.length === 0) {
    throw new OrganizationValidationError('name cannot be empty');
  }
  if (trimmed.length > ORG_NAME_MAX_LENGTH) {
    throw new OrganizationValidationError(`name must be ${ORG_NAME_MAX_LENGTH} characters or fewer`);
  }
  return trimmed;
}

/** Normalize an optional sort_order (defaults to 0). */
export function normalizeSortOrder(raw: unknown): number {
  if (raw === undefined || raw === null) return 0;
  const n = typeof raw === 'number' ? raw : parseInt(String(raw), 10);
  if (!Number.isFinite(n)) {
    throw new OrganizationValidationError('sort_order must be a number');
  }
  return Math.trunc(n);
}

/** Optional client-supplied id (lets the app keep stable ids across offline create). */
function clientId(raw: unknown): string | null {
  return typeof raw === 'string' && UUID_RE.test(raw) ? raw : null;
}

// MARK: - Folders

export async function listFolders(userId: string): Promise<FolderRow[]> {
  const result = await pool.query(
    `SELECT ${FOLDER_RETURNING} FROM folders
      WHERE user_id = $1::uuid
      ORDER BY sort_order ASC, created_at ASC`,
    [userId],
  );
  return result.rows.map(formatFolder);
}

export async function createFolder(
  userId: string,
  name: string,
  sortOrder = 0,
  id: unknown = undefined,
): Promise<FolderRow> {
  const cid = clientId(id);
  const result = await pool.query(
    cid
      ? `INSERT INTO folders (id, user_id, name, sort_order)
         VALUES ($1::uuid, $2::uuid, $3, $4)
         RETURNING ${FOLDER_RETURNING}`
      : `INSERT INTO folders (user_id, name, sort_order)
         VALUES ($1::uuid, $2, $3)
         RETURNING ${FOLDER_RETURNING}`,
    cid ? [cid, userId, name, sortOrder] : [userId, name, sortOrder],
  );
  return formatFolder(result.rows[0]);
}

export async function updateFolder(
  userId: string,
  id: string,
  fields: { name?: string; sortOrder?: number },
): Promise<FolderRow | null> {
  const setClauses: string[] = [];
  const values: any[] = [];
  let i = 1;
  if (fields.name !== undefined) {
    setClauses.push(`name = $${i++}`);
    values.push(fields.name);
  }
  if (fields.sortOrder !== undefined) {
    setClauses.push(`sort_order = $${i++}`);
    values.push(fields.sortOrder);
  }
  if (setClauses.length === 0) {
    throw new OrganizationValidationError('No fields to update');
  }
  setClauses.push('updated_at = NOW()');
  values.push(id, userId);
  const result = await pool.query(
    `UPDATE folders SET ${setClauses.join(', ')}
      WHERE id = $${i}::uuid AND user_id = $${i + 1}::uuid
      RETURNING ${FOLDER_RETURNING}`,
    values,
  );
  return result.rows.length ? formatFolder(result.rows[0]) : null;
}

export async function deleteFolder(userId: string, id: string): Promise<boolean> {
  const result = await pool.query(
    `DELETE FROM folders WHERE id = $1::uuid AND user_id = $2::uuid RETURNING id`,
    [id, userId],
  );
  return result.rows.length > 0;
}

// MARK: - Lists

export async function listLists(userId: string): Promise<ListRow[]> {
  const result = await pool.query(
    `SELECT ${LIST_RETURNING} FROM lists
      WHERE user_id = $1::uuid
      ORDER BY sort_order ASC, created_at ASC`,
    [userId],
  );
  return result.rows.map(formatList);
}

/**
 * Verifies a folder belongs to the user. Returns true for null (un-filed) so callers
 * can pass through "no folder". Throws on a folder owned by someone else / missing.
 */
async function assertFolderOwned(userId: string, folderId: string | null): Promise<void> {
  if (folderId === null) return;
  if (!UUID_RE.test(folderId)) {
    throw new OrganizationValidationError('folder_id must be a valid id');
  }
  const result = await pool.query(
    `SELECT id FROM folders WHERE id = $1::uuid AND user_id = $2::uuid`,
    [folderId, userId],
  );
  if (result.rows.length === 0) {
    throw new OrganizationValidationError('folder_id does not reference a folder you own');
  }
}

/** Normalize an optional folder_id: undefined → keep, null/'' → unfile, string → set. */
export function normalizeFolderId(raw: unknown): string | null | undefined {
  if (raw === undefined) return undefined;
  if (raw === null) return null;
  if (typeof raw !== 'string') {
    throw new OrganizationValidationError('folder_id must be a string id or null');
  }
  const trimmed = raw.trim();
  return trimmed.length === 0 ? null : trimmed;
}

export async function createList(
  userId: string,
  name: string,
  folderId: string | null = null,
  sortOrder = 0,
  id: unknown = undefined,
): Promise<ListRow> {
  await assertFolderOwned(userId, folderId);
  const cid = clientId(id);
  const result = await pool.query(
    cid
      ? `INSERT INTO lists (id, user_id, name, folder_id, sort_order)
         VALUES ($1::uuid, $2::uuid, $3, $4::uuid, $5)
         RETURNING ${LIST_RETURNING}`
      : `INSERT INTO lists (user_id, name, folder_id, sort_order)
         VALUES ($1::uuid, $2, $3::uuid, $4)
         RETURNING ${LIST_RETURNING}`,
    cid ? [cid, userId, name, folderId, sortOrder] : [userId, name, folderId, sortOrder],
  );
  return formatList(result.rows[0]);
}

export async function updateList(
  userId: string,
  id: string,
  fields: { name?: string; folderId?: string | null; sortOrder?: number },
): Promise<ListRow | null> {
  if (fields.folderId !== undefined) {
    await assertFolderOwned(userId, fields.folderId);
  }
  const setClauses: string[] = [];
  const values: any[] = [];
  let i = 1;
  if (fields.name !== undefined) {
    setClauses.push(`name = $${i++}`);
    values.push(fields.name);
  }
  if (fields.folderId !== undefined) {
    setClauses.push(`folder_id = $${i++}::uuid`);
    values.push(fields.folderId);
  }
  if (fields.sortOrder !== undefined) {
    setClauses.push(`sort_order = $${i++}`);
    values.push(fields.sortOrder);
  }
  if (setClauses.length === 0) {
    throw new OrganizationValidationError('No fields to update');
  }
  setClauses.push('updated_at = NOW()');
  values.push(id, userId);
  const result = await pool.query(
    `UPDATE lists SET ${setClauses.join(', ')}
      WHERE id = $${i}::uuid AND user_id = $${i + 1}::uuid
      RETURNING ${LIST_RETURNING}`,
    values,
  );
  return result.rows.length ? formatList(result.rows[0]) : null;
}

export async function deleteList(userId: string, id: string): Promise<boolean> {
  const result = await pool.query(
    `DELETE FROM lists WHERE id = $1::uuid AND user_id = $2::uuid RETURNING id`,
    [id, userId],
  );
  return result.rows.length > 0;
}

/**
 * Confirms a list belongs to the user — used by tasks.routes before stamping a
 * task's list_id, so a task can't be filed into someone else's List.
 */
export async function listExistsForUser(userId: string, listId: string): Promise<boolean> {
  if (!UUID_RE.test(listId)) return false;
  const result = await pool.query(
    `SELECT id FROM lists WHERE id = $1::uuid AND user_id = $2::uuid`,
    [listId, userId],
  );
  return result.rows.length > 0;
}
