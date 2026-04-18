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
