import { Router, Request, Response } from 'express';
import Joi from 'joi';
import {
  calcCurrentAllocations,
  calcTargetAllocations,
  calcDrift,
  calcActions,
  calcRebalanceScore,
  calcPortfolioHealth
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
    const { rebalance_score, trigger } = calcRebalanceScore(drift, rawActions, total);
    const portfolioHealth = calcPortfolioHealth(current, value.risk_tolerance, rebalance_score);
    const { actions, summary } = await generateRationale(
      value, current, target, drift, rawActions, total, rebalance_score, trigger, portfolioHealth
    );

    res.json({
      strategy: value.strategy,
      risk_tolerance: value.risk_tolerance,
      total_value: total,
      current_allocations: current,
      target_allocations: target,
      drift,
      portfolio_health: portfolioHealth,
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