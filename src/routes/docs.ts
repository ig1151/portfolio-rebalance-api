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
