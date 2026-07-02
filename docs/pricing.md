# Model Pricing

How OpenUsage turns token counts into the estimated dollars on the spend tiles (Claude, Codex, Cursor, Grok). OpenRouter is the exception: its API reports billed dollars directly, so nothing here applies to it.

## Where prices come from

Prices are layered from three sources; when the same model appears in more than one, the higher layer wins:

1. **OpenUsage pricing supplement** — a small JSON file maintained in this repo and published to GitHub Pages. It covers models no public catalog carries (Cursor-native models like `auto` and `composer-*`), fast-variant multipliers, and alias rules that map provider log/CSV slugs to catalog keys.
2. **LiteLLM** — the community-maintained `model_prices_and_context_window.json`, covering the vast majority of API-priced models.
3. **models.dev** — a gap-filler for models LiteLLM misses (e.g. some brand-new or niche models).

The app ships with bundled snapshots of all three, so pricing works offline and on first launch. At runtime each source is refetched about once a day (with ETag revalidation) and cached in `~/Library/Application Support/OpenUsage/pricing/`. A refresh never blocks a usage scan — scans always price against the freshest data already on hand.

Because the supplement is published to GitHub Pages on merge, a pricing correction reaches installed apps within a day — no app update needed.

## How a model name resolves

Log and CSV model names rarely match a catalog key exactly, so resolution tries, in order: supplement alias rules, exact key match, fast-variant handling (a `-fast` suffix resolves the base model and applies its fast multiplier), then fuzzy matching — provider prefixes (`anthropic/`, `xai/`, …), dated suffixes (`claude-sonnet-4` ↔ `claude-sonnet-4-20250514`), and separator differences (`grok-4-3` ↔ `grok-4.3`).

A model no source can price still counts its tokens — the day's tile shows tokens without dollars and a warning triangle lists the unpriced models, rather than silently showing a too-low cost.

## What the estimate includes

Costs are computed per usage event from four token buckets — plain input, cache writes, cache reads, and output — at the model's per-million-token rates, including 1-hour cache-write pricing, the >200k-token long-context tiers where a provider has them, and fast-variant multipliers. When a Claude log line carries an explicit `costUSD`, that value is used as-is. The result is an estimate of API-rate value, not a bill: subscription plans don't charge per token.

## Privacy

The pricing refresh fetches three public price lists (from `raw.githubusercontent.com`, `models.dev`, and this repo's GitHub Pages). These requests carry no usage or log data — nothing about your usage leaves your Mac.

## Maintainer notes

- **Supplement changes** (new Cursor-native model, price correction, new alias): edit `Sources/OpenUsage/Resources/pricing_supplement.json` on `main`, sync entries from [Cursor models & pricing](https://cursor.com/docs/models-and-pricing.md), and update `updated_at`. On merge, `.github/workflows/pricing-supplement.yml` publishes it to gh-pages; installed apps pick it up within a day. The bundled copy ships with the next release for first launches.
- **Bundled snapshots** (`pricing_litellm_snapshot.json`, `pricing_models_dev_snapshot.json`): regenerate occasionally (e.g. before a release) with `script/update_pricing_snapshots.sh`. Staleness is harmless — runtime fetches override them.
