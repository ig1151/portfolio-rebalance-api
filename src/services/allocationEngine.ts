import { RebalanceRequest, RebalanceAction } from '../types';

const STABLECOINS = ['USDC', 'USDT', 'DAI', 'BUSD'];

const RISK_WEIGHTS: Record<string, Record<string, number>> = {
  low:    { BTC: 0.50, ETH: 0.25, stable: 0.25 },
  medium: { BTC: 0.40, ETH: 0.30, alt: 0.20, stable: 0.10 },
  high:   { BTC: 0.30, ETH: 0.25, alt: 0.35, stable: 0.10 }
};

export function calcCurrentAllocations(portfolio: { asset: string; value: number }[], total: number): Record<string, number> {
  const allocs: Record<string, number> = {};
  for (const item of portfolio) {
    allocs[item.asset.toUpperCase()] = Math.round((item.value / total) * 1000) / 1000;
  }
  return allocs;
}

export function calcTargetAllocations(
  request: RebalanceRequest,
  assets: string[],
  total: number
): Record<string, number> {
  const { strategy, risk_tolerance, cash_buffer = 0, constraints = {} } = request;
  const maxSingle = constraints.max_single_asset ?? 0.7;
  const excluded = (constraints.exclude_assets ?? []).map(a => a.toUpperCase());
  const eligibleAssets = assets.filter(a => !excluded.includes(a));
  const investable = 1 - cash_buffer;
  const target: Record<string, number> = {};

  if (strategy === 'equal_weight') {
    const share = Math.round((investable / eligibleAssets.length) * 1000) / 1000;
    for (const asset of eligibleAssets) target[asset] = Math.min(share, maxSingle);
  } else if (strategy === 'risk_adjusted') {
    const weights = RISK_WEIGHTS[risk_tolerance];
    const btcAssets = eligibleAssets.filter(a => a === 'BTC');
    const ethAssets = eligibleAssets.filter(a => a === 'ETH');
    const stableAssets = eligibleAssets.filter(a => STABLECOINS.includes(a));
    const altAssets = eligibleAssets.filter(a => !['BTC', 'ETH'].includes(a) && !STABLECOINS.includes(a));

    for (const a of btcAssets) target[a] = Math.min(weights.BTC ?? 0, maxSingle);
    for (const a of ethAssets) target[a] = Math.min(weights.ETH ?? 0, maxSingle);
    if (stableAssets.length > 0) {
      const stableShare = (weights.stable ?? 0) / stableAssets.length;
      for (const a of stableAssets) target[a] = stableShare;
    }
    if (altAssets.length > 0) {
      const altShare = ((weights.alt ?? 0) * investable) / altAssets.length;
      for (const a of altAssets) target[a] = Math.min(altShare, maxSingle);
    }
  } else if (strategy === 'momentum_tilt') {
    const nonStable = eligibleAssets.filter(a => !STABLECOINS.includes(a));
    const stable = eligibleAssets.filter(a => STABLECOINS.includes(a));
    const stableAlloc = cash_buffer + (stable.length > 0 ? 0.05 : 0);
    const growthAlloc = investable - stableAlloc;
    const btc = nonStable.find(a => a === 'BTC');
    const eth = nonStable.find(a => a === 'ETH');
    const alts = nonStable.filter(a => a !== 'BTC' && a !== 'ETH');
    if (btc) target[btc] = Math.min(growthAlloc * 0.40, maxSingle);
    if (eth) target[eth] = Math.min(growthAlloc * 0.30, maxSingle);
    if (alts.length > 0) {
      const altShare = (growthAlloc * 0.30) / alts.length;
      for (const a of alts) target[a] = Math.min(altShare, maxSingle);
    }
    if (stable.length > 0) {
      for (const a of stable) target[a] = stableAlloc / stable.length;
    }
  }

  if (cash_buffer > 0 && !target['USDC']) target['USDC'] = cash_buffer;

  const sum = Object.values(target).reduce((a, b) => a + b, 0);
  if (sum > 0) {
    for (const key of Object.keys(target)) {
      target[key] = Math.round((target[key] / sum) * 1000) / 1000;
    }
  }
  return target;
}

export function calcDrift(
  current: Record<string, number>,
  target: Record<string, number>
): Record<string, number> {
  const allAssets = new Set([...Object.keys(current), ...Object.keys(target)]);
  const drift: Record<string, number> = {};
  for (const asset of allAssets) {
    const c = current[asset] ?? 0;
    const t = target[asset] ?? 0;
    drift[asset] = Math.round((c - t) * 1000) / 1000;
  }
  return drift;
}

export function calcActions(
  drift: Record<string, number>,
  total: number,
  minTradeSize: number = 100
): Omit<RebalanceAction, 'reason'>[] {
  const actions: Omit<RebalanceAction, 'reason'>[] = [];
  for (const [asset, d] of Object.entries(drift)) {
    const amount = Math.abs(Math.round(d * total));
    if (amount < minTradeSize) continue;
    actions.push({ asset, action: d > 0 ? 'sell' : 'buy', amount_usd: amount });
  }
  return actions;
}

export function calcTurnover(actions: Omit<RebalanceAction, 'reason'>[], total: number): number {
  const totalTraded = actions.reduce((sum, a) => sum + a.amount_usd, 0);
  return Math.round((totalTraded / total) * 100) / 100;
}

export function calcRebalanceScore(
  drift: Record<string, number>,
  actions: Omit<RebalanceAction, 'reason'>[],
  total: number
): { rebalance_score: number; trigger: boolean } {
  const maxDrift = Math.max(...Object.values(drift).map(Math.abs));
  const turnover = calcTurnover(actions, total);
  const driftScore = Math.min(maxDrift * 200, 60);   // up to 60pts
  const turnoverScore = Math.min(turnover * 100, 40); // up to 40pts
  const rebalance_score = Math.round(driftScore + turnoverScore);
  return { rebalance_score, trigger: rebalance_score >= 30 };
}

export function calcPortfolioHealth(
  current: Record<string, number>,
  riskTolerance: string,
  rebalanceScore: number
): { score: number; risk: string; diversification: string } {
  const assets = Object.keys(current);
  const maxAlloc = Math.max(...Object.values(current));
  const stableAlloc = Object.entries(current)
    .filter(([a]) => STABLECOINS.includes(a))
    .reduce((sum, [, v]) => sum + v, 0);

  // Diversification: penalize concentration
  const diversification = maxAlloc > 0.7 ? 'poor' : maxAlloc > 0.5 ? 'moderate' : assets.length >= 4 ? 'good' : 'moderate';

  // Risk posture vs tolerance
  const highRiskAlloc = Object.entries(current)
    .filter(([a]) => !['BTC', 'ETH', ...STABLECOINS].includes(a))
    .reduce((sum, [, v]) => sum + v, 0);

  const risk = highRiskAlloc > 0.4 ? 'high' : stableAlloc > 0.3 ? 'low' : 'moderate';

  // Health score
  const divScore = diversification === 'good' ? 40 : diversification === 'moderate' ? 25 : 10;
  const driftPenalty = Math.min(rebalanceScore / 2, 30);
  const riskScore = risk === riskTolerance ? 30 : 15;
  const score = Math.max(0, Math.min(100, Math.round(divScore + riskScore + 30 - driftPenalty)));

  return { score, risk, diversification };
}