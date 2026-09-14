import { describe, expect, it, vi } from 'vitest';
import {
  copyTable,
  shouldDeleteDestinationRows,
  TABLE_PLAN,
} from './copy-user-data.js';

function fields(names: string[]) {
  return names.map((name) => ({ name }));
}

describe('copy-user-data schema drift and generated ordering', () => {
  it('copies durable conversation proposals after their parent messages', () => {
    const messages = TABLE_PLAN.findIndex((item) => item.table === 'rem_conversation_messages');
    const proposals = TABLE_PLAN.findIndex((item) => item.table === 'rem_conversation_task_proposals');
    expect(messages).toBeGreaterThanOrEqual(0);
    expect(proposals).toBeGreaterThan(messages);
  });

  it('never deletes the parent user row that owns destination-only cascading data', () => {
    const plan = TABLE_PLAN.find((item) => item.table === 'users');
    expect(plan).toBeDefined();
    if (!plan) throw new Error('users plan missing');
    expect(shouldDeleteDestinationRows(plan, ['id', 'email'])).toBe(false);
    expect(shouldDeleteDestinationRows(
      { table: 'rem_conversations', userKey: 'user_id' },
      [],
    )).toBe(false);
  });

  it('skips a destination-only table instead of querying an older source schema', async () => {
    const src = { query: vi.fn().mockResolvedValue({ rows: [] }) };
    const dest = { query: vi.fn() };
    const copied = await copyTable(
      src as any,
      dest as any,
      { table: 'rem_conversations', userKey: 'user_id' },
      '11111111-1111-4111-8111-111111111111',
    );
    expect(copied).toBe(0);
    expect(src.query).toHaveBeenCalledOnce();
    expect(dest.query).not.toHaveBeenCalled();
  });

  it('orders transcript rows by source seq while regenerating destination seq values', async () => {
    const columns = ['id', 'seq', 'conversation_id', 'user_id', 'role', 'content'];
    const src = {
      query: vi.fn()
        .mockResolvedValueOnce({ rows: columns.map((column_name) => ({ column_name })) })
        .mockResolvedValueOnce({
          rowCount: 2,
          fields: fields(columns),
          rows: [
            { id: 'm1', seq: '7', conversation_id: 'c1', user_id: 'u1', role: 'user', content: 'first' },
            { id: 'm2', seq: '8', conversation_id: 'c1', user_id: 'u1', role: 'assistant', content: 'second' },
          ],
        }),
    };
    const dest = {
      query: vi.fn()
        .mockResolvedValueOnce({ rows: columns.map((column_name) => ({ column_name })) })
        .mockResolvedValue({ rowCount: 1, rows: [] }),
    };
    const plan = TABLE_PLAN.find((item) => item.table === 'rem_conversation_messages');
    expect(plan).toBeDefined();
    if (!plan) throw new Error('rem_conversation_messages plan missing');
    const copied = await copyTable(src as any, dest as any, plan, 'u1');
    expect(copied).toBe(2);
    expect(src.query.mock.calls[1][0]).toContain('ORDER BY "seq"');
    const insertSql = dest.query.mock.calls[1][0] as string;
    expect(insertSql).not.toContain('"seq"');
    expect(dest.query.mock.calls[1][1]).toEqual(['m1', 'c1', 'u1', 'user', 'first']);
    expect(dest.query.mock.calls[2][1]).toEqual(['m2', 'c1', 'u1', 'assistant', 'second']);
  });

  it('upserts the preserved user parent and still nulls cross-environment secrets', async () => {
    const columns = ['id', 'email', 'gateway_url'];
    const src = {
      query: vi.fn()
        .mockResolvedValueOnce({ rows: columns.map((column_name) => ({ column_name })) })
        .mockResolvedValueOnce({
          rowCount: 1,
          fields: fields(columns),
          rows: [{ id: 'u1', email: 'owner@example.com', gateway_url: 'https://prod-gateway' }],
        }),
    };
    const dest = {
      query: vi.fn()
        .mockResolvedValueOnce({ rows: columns.map((column_name) => ({ column_name })) })
        .mockResolvedValue({ rowCount: 1, rows: [] }),
    };
    const plan = TABLE_PLAN.find((item) => item.table === 'users');
    expect(plan).toBeDefined();
    if (!plan) throw new Error('users plan missing');
    const copied = await copyTable(src as any, dest as any, plan, 'u1');
    expect(copied).toBe(1);
    expect(dest.query.mock.calls[1][0]).toContain('ON CONFLICT ("id") DO UPDATE SET');
    expect(dest.query.mock.calls[1][1]).toEqual(['u1', 'owner@example.com', null]);
  });
});
