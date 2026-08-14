# Access Control Architecture

## Registry-Centric Authority Model

All operational roles (`ADMIN_ROLE`, `KEEPER_ROLE`, `MINTER_ROLE`) are granted and checked on **Registry**. Protocol contracts use `RegistryClient` mixins (`onlyValidRole`, `onlyValidContract`) — they do not hold local AccessControl roles for protocol operations.

```mermaid
%%{init: {'theme':'base', 'themeVariables': { 'fontSize': '28px', 'primaryTextColor': '#000000'}, 'flowchart': {'nodeSpacing': 120, 'rankSpacing': 120, 'padding': 30}}}%%
graph TB
    DAO["DAO / Admin Timelock<br/>(ADMIN_ROLE on Registry)"]
    CREQueue["CREQueueExecutor<br/>(KEEPER_ROLE)"]
    CREStrategy["CREStrategyExecutor<br/>(KEEPER_ROLE)"]
    BreakGlass["Break-glass multisig<br/>OPT-IN, off by default<br/>(FREEZE_RUNBOOK §0.1)"]
    Security["Security multisig<br/>(SECURITY_ROLE)"]
    Deployer["Deployer<br/>(temporary ADMIN at init)"]
    Keystone["KeystoneForwarder<br/>(no protocol role)"]
    
    Registry["Registry<br/>Static"]
    
    EVE["EVE"]
    AMM["AMM"]
    Controller["Controller"]
    ExitQueue["ExitQueue"]
    StrategyManager["StrategyManager"]
    Oracle["Oracle"]
    UniCLStrat["UniCLStrat"]
    
    DAO --> Registry
    CREQueue --> Registry
    CREStrategy --> Registry
    BreakGlass -.->|"KEEPER_ROLE only if DAO opts in"| Registry
    Security --> Registry
    Deployer -.->|"renounce after deploy"| Registry
    Keystone -.->|"onReport only"| CREQueue
    Keystone -.->|"onReport only"| CREStrategy
    
    Registry -.->|"MINTER_ROLE check"| EVE
    Registry -.->|"ADMIN / peer keys"| AMM
    Registry -.->|"KEEPER / ADMIN"| Controller
    Registry -.->|"ADMIN; AMM/CONTROLLER caller"| ExitQueue
    Registry -.->|"ADMIN / CONTROLLER caller"| StrategyManager
    Registry -.->|"ADMIN"| Oracle
    Registry -.->|"ADMIN; SM caller"| UniCLStrat
    CREQueue -.->|"priceBatch / processRequests"| Controller
    CREStrategy -.->|"deposit / withdraw / rebalance / sync / harvest / exitLiquidity"| Controller
    BreakGlass -.->|"same surface, manually"| Controller
    Security -->|"pause() — instant keeper stop"| Controller
    
    classDef role fill:#FFB6C1,stroke:#DC143C
    classDef optin fill:#FFF0F5,stroke:#DC143C,stroke-dasharray: 6 4
    classDef hub fill:#F0E68C,stroke:#B8860B,stroke-width:4px
    classDef contract fill:#90EE90,stroke:#006400
    classDef external fill:#D3D3D3,stroke:#696969
    
    class DAO,CREQueue,CREStrategy,Security,Deployer role
    class BreakGlass optin
    class Registry hub
    class EVE,AMM,Controller,ExitQueue,StrategyManager,Oracle,UniCLStrat contract
    class Keystone external
```

## Access Control Matrix (via Registry)

| Function | Checked role / caller | Contract |
|----------|----------------------|----------|
| **Mint / Burn EVE** | `MINTER_ROLE` on Registry | EVE |
| **Set connector weight / pause AMM** | `ADMIN_ROLE` on Registry | AMM |
| **processRedemption** | Registered `CONTROLLER` | AMM |
| **Keeper ops / emergency / pause Controller** | `KEEPER_ROLE` or `ADMIN_ROLE` on Registry | Controller |
| **push / pull / price batch** | Registered `AMM` / `CONTROLLER`; gated by `whenNotPaused` | ExitQueue |
| **close request** | Registered `AMM`; works when paused (emergency withdrawal) | ExitQueue |
| **pause ExitQueue** | `ADMIN_ROLE` on Registry | ExitQueue |
| **add/remove strategy / force-remove / pause SM / fee config** | `ADMIN_ROLE` on Registry | StrategyManager |
| **harvestPerformanceFeeFromStrategy(s)** | `ADMIN_ROLE` or `KEEPER_ROLE` on Registry | Controller |
| **harvestPerformanceFeeFromStrategy(s)** (delegate) | Registered `CONTROLLER` | StrategyManager |
| **depositToStrategies / withdraw / rebalance / sync** | Registered `CONTROLLER` | StrategyManager |
| **totalNAVInETH** | — (view; requires `AMM` key registered) | StrategyManager |
| **updateTokenInfo** | `ADMIN_ROLE` on Registry | Oracle |
| **pause / upgrade Oracle** | `ADMIN_ROLE` on Registry | Oracle |
| **deposit / withdraw / rebalance / sync** | Registered `STRATEGY_MANAGER` | UniCLStrat |
| **emergencyExit / config** | `ADMIN_ROLE` or `SECURITY_ROLE` on Registry | UniCLStrat |
| **registerContract / grantRole** | `ADMIN_ROLE` on Registry | Registry |

## Protocol Roles (Registry)

| Role | Typical grantee | Purpose |
|------|-----------------|----------|
| `ADMIN_ROLE` | DAO | Register contracts, grant/revoke roles, Oracle feed configuration, pause/upgrade modules |
| `KEEPER_ROLE` | CREQueueExecutor + CREStrategyExecutor. A manual break-glass multisig is **opt-in and off by default** — see [FREEZE_RUNBOOK §0.1](../docs/FREEZE_RUNBOOK.md) | Controller automation via CRE `onReport` → recomputed keeper calls |
| `SECURITY_ROLE` | Security multisig | Instant `pause()` everywhere (which is also the containment path for a compromised keeper — every Controller keeper function is `whenNotPaused`), emergency capital recovery, timelock `CANCELLER_ROLE`. Cannot unpause, configure, or upgrade |
| `MINTER_ROLE` | AMM, StrategyManager | EVE mint/burn (AMM enter/exit; SM performance-fee harvest) |

## Deployer Admin Lifecycle

1. **Registry.initialize(dao)**: grants `ADMIN_ROLE` to `dao` and `msg.sender` (deployer).
2. **Modular deploy**: deployer uses ADMIN to `registerContract` / `grantRoles`.
3. **Finalize**: if `deployer != dao`, deployer calls `renounceRole(ADMIN_ROLE, deployer)` on Registry (works even when Registry is paused).
4. **Post-finalize**: only `dao` (and other granted roles) retain Registry authority.

## Key Security Principles

- **Single source of truth**: Registry holds addresses (`Auth`) and roles (`Auth`).
- **No local DEPLOYER_ROLE**: Removed from Controller, ExitQueue, EVE, StrategyManager.
- **Peer immutability by governance**: Addresses change only via Registry `registerContract` (ADMIN).
- **Fail-closed peers**: Missing or unregistered keys revert with `RegistryContractNotRegistered`.
- **Immutable core**: EVE, AMM, and strategy contracts are not upgradeable.
