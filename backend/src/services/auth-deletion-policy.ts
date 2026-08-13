export function flyAppsForAccountDeletion(
  currentAppName: string | null | undefined,
  retainedAppNames: Array<string | null | undefined>,
): string[] {
  return [...new Set([currentAppName, ...retainedAppNames]
    .map((value) => value?.trim())
    .filter((value): value is string => Boolean(value)))];
}

export function canRemoveInterruptedMigrationCheckpoint(
  migration: {
    source_app_name: string;
    target_app_name: string;
    target_ownership_state: string;
  },
  confirmedDeletedAppNames: ReadonlySet<string>,
): boolean {
  // `unclaimed` is ambiguous, not unowned: strict app creation may have succeeded even if its
  // response or the following ownership-marker write was lost. Keep the durable user association
  // until ownership is explicitly reconciled. Unknown future states also fail closed.
  if (!['owned', 'disproven'].includes(migration.target_ownership_state)) return false;
  const ownedApps = [
    migration.source_app_name,
    ...(migration.target_ownership_state === 'owned' ? [migration.target_app_name] : []),
  ];
  return ownedApps
    .every((appName) => confirmedDeletedAppNames.has(appName));
}

/** Fly DELETE is idempotently complete when the app is already absent. */
export function isFlyAppAlreadyDeletedError(error: unknown): boolean {
  return String(error instanceof Error ? error.message : error).includes('Fly API 404');
}
