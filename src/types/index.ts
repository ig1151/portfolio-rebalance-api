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
