# TurboDraft Install Wizard Flow

This documents the full behavior of `scripts/install` so you can review and evolve it.

## High-level state flow

```mermaid
flowchart TD
  A[Start scripts/install] --> B{Mode provided?}
  B -- Yes --> C[Use provided mode]
  B -- No --> D{--yes?}
  D -- Yes --> E[Auto-select install/update based on existing install]
  D -- No --> F[Show wizard menu]
  F --> C
  E --> C

  C --> G{Mode}
  G -- install/update --> H[Build release]
  H --> I[Link binaries]
  I --> J[LaunchAgent action]
  J --> K[Optional shell config prompts]
  K --> L[Verify + summary]

  G -- configure --> M[Set shell config + LaunchAgent action]
  M --> L

  G -- repair --> N[Build release + relink + LA restart/install]
  N --> L

  G -- uninstall --> O[Confirm]
  O --> P[Remove symlinks + optional LA uninstall]
  P --> L

  G -- exit --> Q[No changes]
```

## Agent-guided interactive flow

```mermaid
sequenceDiagram
  participant U as User
  participant A as Agent
  participant I as scripts/install

  A->>U: Ask mode (install/update/configure/repair/uninstall)
  U-->>A: Mode choice
  A->>U: Ask LaunchAgent preference
  U-->>A: LaunchAgent choice
  A->>U: Ask PATH/VISUAL preference
  U-->>A: Shell config choices
  A->>I: Run scripts/install with explicit flags
  I-->>A: Build/link/config output
  A->>U: Verification + changes report + rollback command
```

## Detailed decision table

| Decision | Input | Behavior |
|---|---|---|
| Mode source | `--mode` present | Uses provided mode directly |
| Mode source | no `--mode`, `--yes` | Auto-chooses `install` or `update` based on existing install |
| Mode source | no `--mode`, interactive | Shows mode picker menu |
| Build step | install/update/repair | Runs `swift build -c release` |
| Symlink step | install/update/repair | Links `turbodraft`, `turbodraft-app`, `turbodraft-bench` |
| LaunchAgent | `--launch-agent auto` | Interactive ask (when needed) or restart if already installed |
| LaunchAgent | explicit action | Runs explicit install/restart/skip/uninstall path |
| Shell config | explicit `--set-path/--set-visual` | Applies requested yes/no choices |
| Shell config | interactive install/configure | Prompts user and applies chosen options |

## Post-run verification contract

1. `turbodraft --help`
2. `scripts/turbodraft-launch-agent status`
3. shell config review (`PATH`, `VISUAL`)
4. user-facing summary with rollback (`scripts/install --mode uninstall`)
