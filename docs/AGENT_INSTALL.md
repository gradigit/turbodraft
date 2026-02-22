# TurboDraft Agent Install / Configure Guide

Use this when an AI agent is asked to install or reconfigure TurboDraft in a local cloned repo.

## 1) Agent must run as an interactive wizard (required)

Before any install/config/uninstall command:

1. Ask the user which mode they want:
   - install/update
   - configure
   - repair
   - uninstall
2. Ask LaunchAgent preference:
   - install
   - restart
   - skip
   - uninstall
3. Ask shell-config preference:
   - update PATH
   - set VISUAL

If your environment has a dedicated question/choice tool, use it (`AskUserQuestion`, `Question`, etc.). Otherwise ask in chat.
Never assume `--yes` unless the user explicitly requests non-interactive automation.

## 2) Command recipes

### Guided wizard (recommended default)

```sh
scripts/install
```

### Non-interactive install/update

```sh
scripts/install --mode install --yes
```

### Explicit configure path

```sh
scripts/install --mode configure --yes --launch-agent <install|restart|skip|uninstall> --set-path <yes|no> --set-visual <yes|no>
```

### Repair

```sh
scripts/install --mode repair --yes
```

### Uninstall

```sh
scripts/install --mode uninstall
```

## 3) Verification checklist

After running install/config/repair:

1. `turbodraft --help` succeeds.
2. `scripts/turbodraft-launch-agent status` matches the user’s selected agent behavior.
3. Shell config reflects selected options (`PATH`, `VISUAL`).

## 4) What to report back to the user

Always return:

- selected mode
- commands executed
- files changed (symlinks, LaunchAgent plist, shell rc)
- current status
- rollback/uninstall command
