# Fee-on-transfer compatibility verification

Base: `734df96a1391e95dd40843210997da0b9f3ab05e` (source viewed with `git show`).

## Disposition

- **A — FINDING (Low):** the exact-input net minimum and exact-output delivery promise are
  enforced on the Converter's receipt, not on the authorized caller's receipt. A taxed final
  `Converter -> caller` transfer can therefore deliver less than the promised amount. Exact-input
  returns and `SwapExecuted.amountOut` report the pre-tax amount; exact-output has no output return
  but its event reports the nominal exact output.
- **B — FINDING (Informational):** neither path verifies the amount actually received in the
  initial `caller -> Converter` pull. With a taxed input and a same-token pre-existing Converter
  balance, execution/refund can consume that balance. This is real accounting behavior, but it
  requires a non-standard configured token, residual/donated Converter balance, and an authorized
  caller; intended production assets are documented as standard assets.

Overall this is a low-severity unsupported-token/configuration weakness, not a permissionless
drain of ordinary production routes.

## A: output is checked before the final taxed transfer

Exact-input pulls the nominal input at `Converter.sol:387`, snapshots only the Converter's output
balance at `:389`, and measures produced output at `:402`. It checks that gross Converter receipt
against `_minAmountOut` at `:404`, then transfers the same nominal amount to `msg.sender` at `:406`
and returns/emits it at `:402,408`. There is no caller-balance delta. This conflicts with the
interface description that `_amountOut` is the amount “received” (`IConverter.sol:142-155`).

Exact-output snapshots the Converter's output balance at `Converter.sol:170`, requires the
adapter-produced delta to be at least the requested amount at `:193-200`, then transfers exactly
the requested nominal amount at `:209` and emits it at `:211`. Thus a token taking fee specifically
on the last transfer leaves the caller below the exact amount although the transaction succeeds.

The Uniswap adapter deliberately sets the swap recipient to the Converter (`Converter.sol:178,398`;
`UniswapV3ConverterAdapter.sol:229-237,267-275`). Consequently, its router minimum/exact-output
semantics also end at the Converter. `SafeERC20` checks call success/return data, not recipient
balance, so it does not detect a successful fee-taking transfer.

For UniCL, the ordinary WETH-to-paired-token inventory trade uses exact-input
(`UniCLStrat.sol:981-997,1024-1028,1087-1110`). It derives a slippage minimum, but ignores the
Converter return and later operates on actual balances. A taxed paired-token payout therefore
causes a bounded accounting/NAV loss rather than immediate insolvency, while violating the stated
slippage guarantee. UniCL's exact-output use is paired-token-to-WETH during withdrawal
(`:1008-1022,1187-1219`), so its output is standard WETH and A does not affect that intended route.

## B: nominal input can be supplemented by an existing balance

Exact-input performs `safeTransferFrom(..., _amountIn)` at `Converter.sol:387` without measuring
the received input and tells the adapter/router to spend nominal `_amountIn` at `:395-400`. If the
pull delivers `R < _amountIn`, an existing balance can supply `_amountIn - R`; otherwise the
downstream pull normally fails. The event still records nominal `_amountIn` at `:408`.

Exact-output pulls nominal `_amountInMaximum` at `Converter.sol:167` and takes its input baseline
only afterward at `:169`. Its measured `_amountIn` at `:182-191` is therefore only downstream
spend from that post-pull balance, not the caller-to-Converter receipt. The nominal refund
`_amountInMaximum - _amountIn` at `:202-207` also assumes the full maximum arrived. If the inbound
fee is `F`, a pre-existing balance of at least `F` can make both spend and nominal refund succeed,
subsidizing the transfer shortfall. Any fee on the refund can additionally make caller economics
differ from the returned/event input amount.

The adapter approves nominal values (`UniswapV3ConverterAdapter.sol:225-240,263-278`). Its comment
at `:239` recognizes possible residual approval for fee-on-transfer tokens, but only clears the
approval; it neither measures the Converter pull nor final delivery. This is not end-to-end FOT
support. Residual balances are possible through unsolicited ERC-20 transfers and through any
allowed adapter that leaves exact-input unused; Converter has no token sweep and exact-input has no
refund.

UniCL can hit B on both paired-token-to-WETH paths (`UniCLStrat.sol:993-996,1030-1035,1017-1022,
1187-1219`). It grants the Converter unlimited pool-token allowances (`:1266-1271`).

## Permissions, assumptions, and production reachability

- Swap entry points require `CONVERTER_CALLER_ROLE` (`Converter.sol:121-153`). Registration is
  ADMIN-gated and grants that role through StrategyManager (`StrategyManager.sol:152-170`); adapter
  allowlisting is ADMIN-gated (`Converter.sol:263-273`). This is not callable by an arbitrary user.
- UniCL construction and ADMIN-only route updates verify the allowed adapter and enforce only route
  direction WETH <-> `pairedToken` (`UniCLStrat.sol:136-171,444-450,571-615`). They do not test token
  transfer semantics. The deployment script takes pool/routes from environment (`DeployUniCLStrat.s.sol:91-120`).
- The operational comment explicitly assumes “standard assets” (WETH and configured paired token)
  whose approval does not revert (`UniCLStrat.sol:623-631`). The go-live checklist requires route,
  oracle, and role checks but no fee-on-transfer exclusion (`docs/STRATEGY_GUARDRAILS.md:59-103`).
- `DeployAll` is core-only and deploys neither an adapter nor UniCL (`DeployAll.s.sol:39-42`), and
  this revision commits no live paired-token address. Therefore no current production FOT route is
  proven. Reachability requires a timelocked operator choice (or a custom registered strategy) of a
  fee-taking token. Ordinary standard WETH/paired-token deployments are unaffected.

## Verification method

Source proof was sufficient; no candidate test was added and no Forge attempt was used. No audit
output or `test/audit` material was read.

AGENT_STATUS: COMPLETE
