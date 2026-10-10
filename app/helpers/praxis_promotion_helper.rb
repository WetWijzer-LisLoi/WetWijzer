# frozen_string_literal: true

module PraxisPromotionHelper
  # Planned one-user launch prices, excluding VAT; NOT active billing prices.
  # Source: owner-approved PRAXIS_PRICING_STRATEGY_2026-10-07.md, section 3.1
  # (beside the Praxis repository). That strategy supersedes the old runtime
  # and marketing amounts. Praxis is unreleased; every ad must say so.
  PRAXIS_PLANNED_SOLO_MONTHLY_PRICES = { essentials: 29, plus: 59 }.freeze

  def praxis_planned_solo_monthly_prices
    PRAXIS_PLANNED_SOLO_MONTHLY_PRICES
  end
end
