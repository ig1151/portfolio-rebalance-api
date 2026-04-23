import { RebalanceRequest, RebalanceAction, RebalanceSummary, PortfolioHealth } from '../types';

const OPENROUTER_API_URL = 'https://openrouter.ai/api/v1/chat/completions';
const MODEL = 'anthropic/claude-sonnet-4-5';

export async function generateRationale(
  request: RebalanceRequest,
  currentAllocations: Record<string, number>,
  targetAllocations: Record<string, number>,
  drift: Record<string, number>,
  actions: Omit<RebalanceAction, 'reason'>[],
  total: number,
  rebalanceScore: number,
  trigger: boolean,
  portfolioHealth: PortfolioHealth
): Promise<{ actions: RebalanceAction[]; summary: RebalanceSummary }> {
  const apiKey = process.env.OPENROUTER_API_KEY;
  if (!apiKey) throw new Error('OPENROUTER_API_KEY not set');

  const prompt = `You are a portfolio advisor. Generate plain-English reasons for each rebalance action and a portfolio summary.
Strategy: ${request.strategy}
Risk tolerance: ${request.risk_tolerance}
Total portfolio value: $${total}
Cash buffer: ${(request.cash_buffer ?? 0) * 100}%
Rebalance score: ${rebalanceScore}/100 (trigger: ${trigger})
Portfolio health: ${JSON.stringify(portfolioHealth)}
Current allocations: ${JSON.stringify(currentAllocations)}
Target allocations: ${JSON.stringify(targetAllocations)}
Drift: ${JSON.stringify(drift)}
Actions to explain:
${actions.length > 0 ? actions.map(a => `- ${a.action.toUpperCase()} ${a.asset} $${a.amount_usd}`).join('\n') : '- No actions needed'}
Return ONLY valid JSON:
{
  "action_reasons": {
    "ASSET": "one sentence reason for this action"
  },
  "portfolio_risk_posture": "2-4 word description e.g. moderate growth, conservative income, aggressive growth",
  "rebalance_summary": "1-2 sentence summary of what this rebalance achieves and whether it is urgent"
}`;

  const response = await fetch(OPENROUTER_API_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 1024,
      messages: [{ role: 'user', content: prompt }],
      response_format: { type: 'json_object' },
    }),
  });

  if (!response.ok) {
    const err = await response.text();
    throw new Error(`OpenRouter error: ${response.status} ${err}`);
  }

  const data = await response.json() as { choices: { message: { content: string } }[] };
  const text = data.choices[0].message.content.trim().replace(/```json|```/g, '').trim();
  const parsed = JSON.parse(text);

  const actionsWithReasons: RebalanceAction[] = actions.map(a => ({
    ...a,
    reason: parsed.action_reasons?.[a.asset] ?? `${a.action} to align with ${request.strategy} strategy`
  }));

  const turnover = Math.round(actions.reduce((sum, a) => sum + a.amount_usd, 0) / total * 100) / 100;

  return {
    actions: actionsWithReasons,
    summary: {
      rebalance_needed: actions.length > 0,
      rebalance_score: rebalanceScore,
      trigger,
      estimated_turnover: turnover,
      portfolio_risk_posture: parsed.portfolio_risk_posture ?? 'balanced'
    }
  };
}
