import { describe, expect, it } from 'vitest';

import {
  WRITE_AUTONOMY_THRESHOLD,
  canExecuteWrites,
  planOrExecute,
  screenForDeniedAction,
} from './routine-governance.js';

describe('autonomy gate', () => {
  it('only L3+ may execute writes', () => {
    expect(WRITE_AUTONOMY_THRESHOLD).toBe(3);
    expect(canExecuteWrites(0)).toBe(false);
    expect(canExecuteWrites(2)).toBe(false);
    expect(canExecuteWrites(3)).toBe(true);
    expect(canExecuteWrites(4)).toBe(true);
  });

  it('planOrExecute reflects the threshold', () => {
    expect(planOrExecute(1)).toBe('plan');
    expect(planOrExecute(3)).toBe('execute');
  });
});

describe('hard deny list', () => {
  it('passes a benign read-only instruction', () => {
    const r = screenForDeniedAction('Summarize my open tasks and brief me on what is overdue.');
    expect(r.denied).toBe(false);
    expect(r.categories).toEqual([]);
  });

  it('passes when there is no prompt', () => {
    expect(screenForDeniedAction(null).denied).toBe(false);
    expect(screenForDeniedAction(undefined).denied).toBe(false);
    expect(screenForDeniedAction('').denied).toBe(false);
  });

  it('blocks sending email/messages', () => {
    const r = screenForDeniedAction('Send an email to my boss with the weekly update.');
    expect(r.denied).toBe(true);
    expect(r.categories).toContain('send_communications');
  });

  it('blocks legal/financial/immigration actions', () => {
    expect(screenForDeniedAction('Wire money to the contractor.').categories).toContain(
      'legal_financial_immigration',
    );
    expect(screenForDeniedAction('Renew my visa application.').categories).toContain(
      'legal_financial_immigration',
    );
  });

  it('blocks deleting data', () => {
    expect(screenForDeniedAction('Delete all completed tasks.').categories).toContain('delete_data');
  });

  it('blocks changing sharing/permissions', () => {
    expect(screenForDeniedAction('Make this public for the whole team.').categories).toContain(
      'change_sharing',
    );
  });
});
