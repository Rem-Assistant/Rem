const FREE_DAILY = Number(process.env.FREE_PLAN_DAILY_LIMIT) || 50;
const FREE_MONTHLY = Number(process.env.FREE_PLAN_MONTHLY_LIMIT) || 500;
const PRO_DAILY = Number(process.env.PRO_PLAN_DAILY_LIMIT) || 1000;
const PRO_MONTHLY = Number(process.env.PRO_PLAN_MONTHLY_LIMIT) || 20000;

export const PLAN_PRIORITY = {
  free: 0,
  pro: 1,
  enterprise: 2,
} as const;

export const PLAN_LIMITS = {
  free: {
    requestsPerDay: FREE_DAILY,
    requestsPerMonth: FREE_MONTHLY,
    modelTier: 'basic' as const,
  },
  pro: {
    requestsPerDay: PRO_DAILY,
    requestsPerMonth: PRO_MONTHLY,
    modelTier: 'premium' as const,
  },
} as const;

export const MODEL_ROUTES = {
  basic: 'gpt-4o-mini',
  premium: 'gpt-4o',
} as const;

export type PlanName = keyof typeof PLAN_LIMITS;
export type ModelTier = typeof PLAN_LIMITS[PlanName]['modelTier'];
export type BillingStatus = 'active' | 'past_due' | 'cancelled';

export interface PlanLimits {
  requestsPerDay: number;
  requestsPerMonth: number;
  modelTier: ModelTier;
}

export interface UsageStats {
  count: number;
  tokens: number;
}

export interface RemainingQuota {
  day: number;
  month: number;
}
