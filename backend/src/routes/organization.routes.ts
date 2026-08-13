import { Router, Request, Response } from 'express';
import { requireJwt } from '../middleware/auth.js';
import {
  listFolders,
  createFolder,
  updateFolder,
  deleteFolder,
  listLists,
  createList,
  updateList,
  deleteList,
  normalizeName,
  normalizeSortOrder,
  normalizeFolderId,
  OrganizationValidationError,
} from '../services/organization.service.js';

/**
 * Task organization (Sorted-style): Folders group Lists; Lists group Tasks.
 *
 *   GET    /api/v1/folders       — list the user's folders (sort_order, then created)
 *   POST   /api/v1/folders       — create a folder { name, sort_order?, id? }
 *   PATCH  /api/v1/folders/:id   — rename / reorder { name?, sort_order? }
 *   DELETE /api/v1/folders/:id   — delete (its lists survive, un-filed)
 *
 *   GET    /api/v1/lists         — list the user's lists
 *   POST   /api/v1/lists         — create a list { name, folder_id?, sort_order?, id? }
 *   PATCH  /api/v1/lists/:id     — rename / move-to-folder / reorder { name?, folder_id?, sort_order? }
 *   DELETE /api/v1/lists/:id     — delete (its tasks survive, un-filed → inbox)
 *
 * All routes are JWT-scoped to the authed user. Assigning a task to a list is done
 * through the tasks routes (POST/PATCH /tasks with list_id).
 */
const router = Router();

function handleError(res: Response, error: any, label: string) {
  if (error instanceof OrganizationValidationError) {
    return res.status(400).json({ error: error.message });
  }
  console.error(`[ORG] ${label}:`, error.message);
  return res.status(500).json({ error: error.message || label });
}

// MARK: - Folders

router.get('/folders', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const folders = await listFolders(userId);
    return res.json({ folders });
  } catch (error: any) {
    return handleError(res, error, 'Failed to list folders');
  }
});

router.post('/folders', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const name = normalizeName(req.body?.name);
    const sortOrder = normalizeSortOrder(req.body?.sort_order);
    const folder = await createFolder(userId, name, sortOrder, req.body?.id);
    return res.status(201).json(folder);
  } catch (error: any) {
    return handleError(res, error, 'Failed to create folder');
  }
});

router.patch('/folders/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const fields: { name?: string; sortOrder?: number } = {};
    if (req.body?.name !== undefined) fields.name = normalizeName(req.body.name);
    if (req.body?.sort_order !== undefined) fields.sortOrder = normalizeSortOrder(req.body.sort_order);
    const folder = await updateFolder(userId, req.params.id, fields);
    if (!folder) return res.status(404).json({ error: 'Folder not found' });
    return res.json(folder);
  } catch (error: any) {
    return handleError(res, error, 'Failed to update folder');
  }
});

router.delete('/folders/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const deleted = await deleteFolder(userId, req.params.id);
    if (!deleted) return res.status(404).json({ error: 'Folder not found' });
    return res.status(204).send();
  } catch (error: any) {
    return handleError(res, error, 'Failed to delete folder');
  }
});

// MARK: - Lists

router.get('/lists', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const lists = await listLists(userId);
    return res.json({ lists });
  } catch (error: any) {
    return handleError(res, error, 'Failed to list lists');
  }
});

router.post('/lists', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const name = normalizeName(req.body?.name);
    const folderId = normalizeFolderId(req.body?.folder_id) ?? null;
    const sortOrder = normalizeSortOrder(req.body?.sort_order);
    const list = await createList(userId, name, folderId, sortOrder, req.body?.id);
    return res.status(201).json(list);
  } catch (error: any) {
    return handleError(res, error, 'Failed to create list');
  }
});

router.patch('/lists/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const fields: { name?: string; folderId?: string | null; sortOrder?: number } = {};
    if (req.body?.name !== undefined) fields.name = normalizeName(req.body.name);
    if (req.body?.folder_id !== undefined) fields.folderId = normalizeFolderId(req.body.folder_id) ?? null;
    if (req.body?.sort_order !== undefined) fields.sortOrder = normalizeSortOrder(req.body.sort_order);
    const list = await updateList(userId, req.params.id, fields);
    if (!list) return res.status(404).json({ error: 'List not found' });
    return res.json(list);
  } catch (error: any) {
    return handleError(res, error, 'Failed to update list');
  }
});

router.delete('/lists/:id', requireJwt, async (req: Request, res: Response) => {
  try {
    const userId = (req as Request & { userId: string }).userId;
    const deleted = await deleteList(userId, req.params.id);
    if (!deleted) return res.status(404).json({ error: 'List not found' });
    return res.status(204).send();
  } catch (error: any) {
    return handleError(res, error, 'Failed to delete list');
  }
});

export default router;
