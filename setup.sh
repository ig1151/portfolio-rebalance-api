#!/bin/bash
set -e

mkdir -p src/{routes,middleware,services,types}

cat > package.json << 'EOF'
{
  "name": "portfolio-rebalance-api",
  "version": "1.0.0",
  "description": "Agent-ready portfolio rebalancing API. Returns target allocations, drift analysis and rebalance actions for any crypto portfolio.",
  "main": "dist/index.js",
  "scripts": {
    "dev": "ts-node-dev --respawn --transpile-only src/index.ts",
    "build": "tsc",
    "start": "node dist/index.js"
  },
  "dependencies": {
    "@anthropic-ai/sdk": "^0.20.0",
    "compression": "^1.7.4",
    "cors": "^2.8.5",
    "dotenv": "^16.3.1",
    "express": "^4.18.2",
    "express-rate-limit": "^7.1.5",
    "helmet": "^7.1.0",
    "joi": "^17.11.0"
  },
  "devDependencies": {
    "@types/compression": "^1.7.5",
    "@types/cors": "^2.8.17",
    "@types/express": "^4.17.21",
    "@types/node": "^20.10.0",
    "ts-node-dev": "^2.0.0",
    "typescript": "^5.3.2"
  }
}
EOF

cat > tsconfig.json << 'EOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "module": "commonjs",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true
  },
  "include": ["src/**/*"],
  "exclude": ["node_modules", "dist"]
}
EOF

cat > render.yaml << 'EOF'
services:
  - type: web
    name: portfolio-rebalance-api
    env: node
    buildCommand: npm install && npm run build
    startCommand: node dist/index.js
    healthCheckPath: /v1/health
    envVars:
      - key: NODE_ENV
        value: production
      - key: ANTHROPIC_API_KEY
        sync: false
EOF

cat > .gitignore << 'EOF'
node_modules/
dist/
.env
*.log
EOF

cat > .env << 'EOF'
PORT=3000
ANTHROPIC_API_KEY=your_key_here
EOF

cat > src/types/index.ts << 'EOF'
export interface PortfolioAsset {
  asset: string;
  value: number;
}

export interface Constraints {
  max_single_asset?: number;
  min_trade_size?: number;
  exclude_assets?: string[];
}

export interface RebalanceRequest {
  portfolio: PortfolioAsset[];
  strategy: 'risk_adjusted' | 'equal_weight' | 'momentum_tilt';
  risk_tolerance: 'low' | 'medium' | 'high';
  constraints?: Constraints;
  cash_buffer?: number;
}

export interface RebalanceAction {
  asset: string;
  action: 'buy' | 'sell' | 'hold';
  amount_usd: number;
  reason: string;
}

export interface RebalanceSummary {
  rebalance_needed: boolean;
  estimated_turnover: number;
  portfolio_risk_posture: string;
}

export interface RebalanceResponse {
  strategy: string;
  risk_tolerance: string;
  total_value: number;
  current_allocations: Record<string, number>;
  target_allocations: Record<string, number>;
  drift: Record<string, number>;
  actions: RebalanceAction[];
  summary: RebalanceSummary;
  generated_at: string;
}
EOF

cat > src/middleware/logger.ts << 'EOF'
export const logger = {
  info: (obj: unknown, msg?: string) =>
    console.log(JSON.stringify({ level: 'info', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
  warn: (obj: unknown, msg?: string) =>
    console.warn(JSON.stringify({ level: 'warn', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
  error: (obj: unknown, msg?: string) =>
    console.error(JSON.stringify({ level: 'error', ...(typeof obj === 'object' ? obj : { data: obj }), msg })),
};
EOF

cat > src/middleware/requestLogger.ts << 'EOF'
import { Request, Response, NextFunction } from 'express';
import { logger } from './logger';

export function requestLogger(req: Request, res: Response, next: NextFunction): void {
  const start = Date.now();
  res.on('finish', () => {
    logger.info({ method: req.method, path: req.path, status: res.statusCode, ms: Date.now() - start });
  });
  next();
}
EOF

cat > src/middleware/rateLimiter.ts << 'EOF'
import rateLimit from 'express-rate-limit';

export const rateLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  standardHeaders: true,
  legacyHeaders: false,
  message: {
    error: 'Too many requests',
    message: 'Rate limit exceeded. Max 100 requests per 15 minutes.'
  }
});
EOF

cat > src/services/allocationEngine.ts << 'EOF'
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
    for (const asset of eligibleAssets) {
      target[asset] = Math.min(share, maxSingle);
    }
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
    // Tilt toward non-stable assets, reduce stables
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

  if (cash_buffer > 0 && !target['USDC']) {
    target['USDC'] = cash_buffer;
  }

  // Normalize to sum to 1
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
    actions.push({
      asset,
      action: d > 0 ? 'sell' : 'buy',
      amount_usd: amount
    });
  }
  return actions;
}

export function calcTurnover(actions: Omit<RebalanceAction, 'reason'>[], total: number): number {
  const totalTraded = actions.reduce((sum, a) => sum + a.amount_usd, 0);
  return Math.round((totalTraded / total) * 100) / 100;
}
EOF

cat > src/services/rationaleEngine.ts << 'EOF'
import Anthropic from '@anthropic-ai/sdk';
import { RebalanceRequest, RebalanceAction, RebalanceSummary } from '../types';

const client = new Anthropic();

export async function generateRationale(
  request: RebalanceRequest,
  currentAllocations: Record<string, number>,
  targetAllocations: Record<string, number>,
  drift: Record<string, number>,
  actions: Omit<RebalanceAction, 'reason'>[],
  total: number
): Promise<{ actions: RebalanceAction[]; summary: RebalanceSummary }> {
  const prompt = `You are a portfolio advisor. Generate plain-English reasons for each rebalance action and a portfolio summary.

Strategy: ${request.strategy}
Risk tolerance: ${request.risk_tolerance}
Total portfolio value: $${total}
Cash buffer: ${(request.cash_buffer ?? 0) * 100}%

Current allocations: ${JSON.stringify(currentAllocations)}
Target allocations: ${JSON.stringify(targetAllocations)}
Drift: ${JSON.stringify(drift)}

Actions to explain:
${actions.map(a => `- ${a.action.toUpperCase()} ${a.asset} $${a.amount_usd}`).join('\n')}

Return ONLY valid JSON:
{
  "action_reasons": {
    "ASSET": "one sentence reason for this action"
  },
  "portfolio_risk_posture": "2-4 word description e.g. moderate growth, conservative income, aggressive growth",
  "rebalance_summary": "1-2 sentence summary of what this rebalance achieves"
}`;

  const message = await client.messages.create({
    model: 'claude-sonnet-4-20250514',
    max_tokens: 1024,
    messages: [{ role: 'user', content: prompt }]
  });

  const content = message.content[0];
  if (content.type !== 'text') throw new Error('Unexpected response from Claude');
  const text = content.text.trim().replace(/```json|```/g, '').trim();
  const parsed = JSON.parse(text);

  const actionsWithReasons: RebalanceAction[] = actions.map(a => ({
    ...a,
    reason: parsed.action_reasons?.[a.asset] ?? `${a.action} to align with ${request.strategy} strategy`
  }));

  const rebalanceNeeded = actions.length > 0;
  const turnover = Math.round(actions.reduce((sum, a) => sum + a.amount_usd, 0) / total * 100) / 100;

  return {
    actions: actionsWithReasons,
    summary: {
      rebalance_needed: rebalanceNeeded,
      estimated_turnover: turnover,
      portfolio_risk_posture: parsed.portfolio_risk_posture ?? 'balanced'
    }
  };
}
EOF

cat > src/routes/rebalance.ts << 'EOF'
import { Router, Request, Response } from 'express';
import Joi from 'joi';
import {
  calcCurrentAllocations,
  calcTargetAllocations,
  calcDrift,
  calcActions
} from '../services/allocationEngine';
import { generateRationale } from '../services/rationaleEngine';
import { logger } from '../middleware/logger';

const router = Router();

const schema = Joi.object({
  portfolio: Joi.array().items(
    Joi.object({
      asset: Joi.string().min(1).max(20).required(),
      value: Joi.number().min(0).required()
    })
  ).min(1).max(20).required(),
  strategy: Joi.string().valid('risk_adjusted', 'equal_weight', 'momentum_tilt').required(),
  risk_tolerance: Joi.string().valid('low', 'medium', 'high').required(),
  constraints: Joi.object({
    max_single_asset: Joi.number().min(0).max(1).optional(),
    min_trade_size: Joi.number().min(0).optional(),
    exclude_assets: Joi.array().items(Joi.string()).optional()
  }).optional(),
  cash_buffer: Joi.number().min(0).max(0.5).optional()
});

router.post('/', async (req: Request, res: Response): Promise<void> => {
  const { error, value } = schema.validate(req.body);
  if (error) {
    res.status(400).json({ error: 'Invalid request', message: error.details[0].message });
    return;
  }

  try {
    const portfolio = value.portfolio.map((p: any) => ({
      asset: p.asset.toUpperCase(),
      value: p.value
    }));

    const total = portfolio.reduce((sum: number, p: any) => sum + p.value, 0);
    if (total <= 0) {
      res.status(400).json({ error: 'Invalid portfolio', message: 'Total portfolio value must be greater than 0' });
      return;
    }

    const assets = portfolio.map((p: any) => p.asset);
    const current = calcCurrentAllocations(portfolio, total);
    const target = calcTargetAllocations({ ...value, portfolio }, assets, total);
    const drift = calcDrift(current, target);
    const rawActions = calcActions(drift, total, value.constraints?.min_trade_size ?? 100);
    const { actions, summary } = await generateRationale(value, current, target, drift, rawActions, total);

    res.json({
      strategy: value.strategy,
      risk_tolerance: value.risk_tolerance,
      total_value: total,
      current_allocations: current,
      target_allocations: target,
      drift,
      actions,
      summary,
      generated_at: new Date().toISOString()
    });
  } catch (err: any) {
    const msg: string = err.message || 'Unknown error';
    logger.error({ msg }, 'Rebalance error');
    res.status(500).json({ error: 'Internal server error', message: msg });
  }
});

export default router;
EOF

cat > src/routes/strategies.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    strategies: [
      {
        id: 'risk_adjusted',
        name: 'Risk Adjusted',
        description: 'Allocates based on risk tolerance. Conservative profiles hold more BTC and stables, aggressive profiles tilt toward alts.',
        best_for: 'Investors who want allocation tied to their risk profile',
        risk_levels: ['low', 'medium', 'high']
      },
      {
        id: 'equal_weight',
        name: 'Equal Weight',
        description: 'Distributes portfolio equally across all assets. Simple, unbiased benchmark strategy.',
        best_for: 'Diversified exposure without asset bias',
        risk_levels: ['low', 'medium', 'high']
      },
      {
        id: 'momentum_tilt',
        name: 'Momentum Tilt',
        description: 'Overweights growth assets (BTC, ETH, alts) and minimizes stables. Designed for bull market conditions.',
        best_for: 'Aggressive growth in trending markets',
        risk_levels: ['medium', 'high']
      }
    ]
  });
});

export default router;
EOF

cat > src/routes/health.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    status: 'ok',
    service: 'portfolio-rebalance-api',
    version: '1.0.0',
    uptime: Math.floor(process.uptime()),
    timestamp: new Date().toISOString()
  });
});

export default router;
EOF

cat > src/routes/docs.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    service: 'Portfolio Rebalance API',
    version: '1.0.0',
    description: 'Agent-ready portfolio rebalancing API. Returns target allocations, drift analysis and plain-English rebalance actions for any crypto portfolio.',
    endpoints: [
      { method: 'POST', path: '/v1/rebalance', description: 'Generate rebalance plan for a portfolio' },
      { method: 'GET', path: '/v1/strategies', description: 'List available rebalancing strategies' },
      { method: 'GET', path: '/v1/health', description: 'Health check' },
      { method: 'GET', path: '/docs', description: 'Documentation' },
      { method: 'GET', path: '/openapi.json', description: 'OpenAPI spec' }
    ],
    strategies: ['risk_adjusted', 'equal_weight', 'momentum_tilt'],
    risk_tolerances: ['low', 'medium', 'high'],
    example: {
      portfolio: [
        { asset: 'BTC', value: 6000 },
        { asset: 'ETH', value: 3000 },
        { asset: 'SOL', value: 1000 }
      ],
      strategy: 'risk_adjusted',
      risk_tolerance: 'medium',
      constraints: {
        max_single_asset: 0.5,
        min_trade_size: 100,
        exclude_assets: []
      },
      cash_buffer: 0.05
    }
  });
});

export default router;
EOF

cat > src/routes/openapi.ts << 'EOF'
import { Router, Request, Response } from 'express';
const router = Router();

router.get('/', (_req: Request, res: Response) => {
  res.json({
    openapi: '3.0.0',
    info: { title: 'Portfolio Rebalance API', version: '1.0.0', description: 'Agent-ready portfolio rebalancing API for crypto portfolios' },
    servers: [{ url: 'https://portfolio-rebalance-api.onrender.com' }],
    paths: {
      '/v1/rebalance': {
        post: {
          summary: 'Generate rebalance plan',
          requestBody: {
            required: true,
            content: {
              'application/json': {
                schema: {
                  type: 'object',
                  required: ['portfolio', 'strategy', 'risk_tolerance'],
                  properties: {
                    portfolio: { type: 'array', items: { type: 'object', properties: { asset: { type: 'string' }, value: { type: 'number' } } } },
                    strategy: { type: 'string', enum: ['risk_adjusted', 'equal_weight', 'momentum_tilt'] },
                    risk_tolerance: { type: 'string', enum: ['low', 'medium', 'high'] },
                    constraints: { type: 'object' },
                    cash_buffer: { type: 'number' }
                  }
                }
              }
            }
          },
          responses: { '200': { description: 'Rebalance plan' }, '400': { description: 'Invalid request' } }
        }
      },
      '/v1/strategies': {
        get: { summary: 'List strategies', responses: { '200': { description: 'Strategy list' } } }
      },
      '/v1/health': {
        get: { summary: 'Health check', responses: { '200': { description: 'OK' } } }
      }
    }
  });
});

export default router;
EOF

cat > src/index.ts << 'EOF'
import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import compression from 'compression';
import { requestLogger } from './middleware/requestLogger';
import { rateLimiter } from './middleware/rateLimiter';
import rebalanceRouter from './routes/rebalance';
import strategiesRouter from './routes/strategies';
import healthRouter from './routes/health';
import docsRouter from './routes/docs';
import openapiRouter from './routes/openapi';

const app = express();
const PORT = process.env.PORT || 3000;

app.use(helmet());
app.use(cors());
app.use(compression());
app.use(express.json());
app.use(requestLogger);
app.use(rateLimiter);

app.use('/v1/health', healthRouter);
app.use('/v1/rebalance', rebalanceRouter);
app.use('/v1/strategies', strategiesRouter);
app.use('/docs', docsRouter);
app.use('/openapi.json', openapiRouter);

app.get('/', (_req, res) => {
  res.json({
    service: 'Portfolio Rebalance API',
    version: '1.0.0',
    docs: '/docs',
    health: '/v1/health',
    example: 'POST /v1/rebalance'
  });
});

app.use((_req, res) => {
  res.status(404).json({ error: 'Not found' });
});

app.listen(PORT, () => {
  console.log(JSON.stringify({ level: 'info', msg: `Portfolio Rebalance API running on port ${PORT}` }));
});

export default app;
EOF

echo "✅ All files created."
echo ""
echo "Next steps:"
echo "  1. Edit .env — add your ANTHROPIC_API_KEY"
echo "  2. npm install"
echo "  3. npm run dev"
echo "  4. Test: POST /v1/rebalance"