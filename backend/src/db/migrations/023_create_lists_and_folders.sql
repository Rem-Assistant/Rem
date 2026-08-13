-- Task organization (Sorted-style): a Folder groups Lists; a List groups Tasks.
-- Foundation slice — folders/lists are user-managed; tasks gain an optional
-- list_id so a task can belong to a List (and, transitively, that List's Folder).
-- Mirrors the tasks/task_comments table shape: per-user rows, ON DELETE CASCADE
-- from users, raw parameterized SQL in the service layer (no ORM).

CREATE TABLE IF NOT EXISTS folders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    name VARCHAR(255) NOT NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS lists (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES users(id) ON DELETE CASCADE NOT NULL,
    name VARCHAR(255) NOT NULL,
    -- Deleting a Folder un-files its Lists (they survive as ungrouped) rather
    -- than cascading the delete down to the Lists/Tasks beneath it.
    folder_id UUID REFERENCES folders(id) ON DELETE SET NULL,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_folders_user_id ON folders(user_id);
CREATE INDEX IF NOT EXISTS idx_lists_user_id ON lists(user_id);
CREATE INDEX IF NOT EXISTS idx_lists_folder_id ON lists(folder_id) WHERE folder_id IS NOT NULL;

-- A task may belong to a List. Deleting a List un-files its Tasks (they revert to
-- the unassigned/inbox view) rather than deleting them.
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS list_id UUID REFERENCES lists(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_tasks_list_id ON tasks(list_id) WHERE list_id IS NOT NULL;
