import { describe, expect, it } from 'vitest';
import {
  canRemoveInterruptedMigrationCheckpoint,
  flyAppsForAccountDeletion,
  isFlyAppAlreadyDeletedError,
} from './auth-deletion-policy.js';

describe('flyAppsForAccountDeletion', () => {
  it('includes the current gateway and every retained migration source once', () => {
    expect(flyAppsForAccountDeletion('remclaw-user', [
      'remclaw-pool-one',
      'remclaw-pool-two',
      'remclaw-user',
    ])).toEqual(['remclaw-user', 'remclaw-pool-one', 'remclaw-pool-two']);
  });

  it('omits empty infrastructure references', () => {
    expect(flyAppsForAccountDeletion(null, [null, '', '  '])).toEqual([]);
  });

  it('treats only Fly not-found deletion failures as already complete', () => {
    expect(isFlyAppAlreadyDeletedError(new Error('Fly API 404: app not found'))).toBe(true);
    expect(isFlyAppAlreadyDeletedError(new Error('Fly API 500: unavailable'))).toBe(false);
  });

  it('retains an interrupted checkpoint until both owned apps are deleted', () => {
    const migration = {
      source_app_name: 'remclaw-pool-one',
      target_app_name: 'remclaw-user-one',
      target_ownership_state: 'owned',
    };
    expect(canRemoveInterruptedMigrationCheckpoint(
      migration,
      new Set(['remclaw-user-one']),
    )).toBe(false);
    expect(canRemoveInterruptedMigrationCheckpoint(
      migration,
      new Set(['remclaw-pool-one', 'remclaw-user-one']),
    )).toBe(true);
  });

  it('does not require deletion of a disproven migration target', () => {
    expect(canRemoveInterruptedMigrationCheckpoint({
      source_app_name: 'remclaw-pool-one',
      target_app_name: 'remclaw-collision',
      target_ownership_state: 'disproven',
    }, new Set(['remclaw-pool-one']))).toBe(true);
  });

  it('retains an unclaimed checkpoint after deleting the known source', () => {
    expect(canRemoveInterruptedMigrationCheckpoint({
      source_app_name: 'remclaw-pool-one',
      target_app_name: 'remclaw-ambiguous',
      target_ownership_state: 'unclaimed',
    }, new Set(['remclaw-pool-one']))).toBe(false);
  });
});
