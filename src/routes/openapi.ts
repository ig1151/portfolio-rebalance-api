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
