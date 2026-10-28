# nvc

A single-file Neovim setup laid out like an AI IDE: file tree on the left, editor in the middle, and Claude Code / opencode on the right. It also edits Jupyter notebooks inline. Built on Windows + WezTerm; a matching Ghostty config is included.

## Layout and keys

Leader is `\`, so Space never waits on a shortcut.

| Key | Action |
|-----|--------|
| `Alt+v` | Show / hide file tree |
| `Alt+e` | Show / hide editor |
| `Alt+c` | Show / hide Claude |
| `Alt+o` | Show / hide opencode |
| `Alt+h/j/k/l` | Move between panes (works in every mode) |
| `Ctrl+V` | Paste system clipboard (in the Claude pane: text or image, whichever was copied) |
| `Alt+V` | In the Claude pane: paste image (toggles the tree everywhere else) |
| `\w` / `\q` / `Ctrl+S` | Save / quit window / save |
| `Alt+f` | Open folder: recent, `D:/Codes`, browse anywhere, new folder / file, or type any path |
| `Alt+n` / `Alt+Shift+n` | New file / folder |
| `Ctrl+P` | Go to file |
| `\gs` `\gd` `\gl` `\gb` `\go` | Git: changed files, changed lines, file history, blame line, open on GitHub |
| `\x` / `\ls` / `\u` | Problems / symbols / undo history |

Press `\` and wait to see the rest (which-key).

Each folder remembers its open files and reopens them. Files save themselves when you leave them or switch away from Neovim, so Claude always reads what you see.

## Plugins

lazy.nvim (bootstraps itself), snacks.nvim (explorer, terminals, inline images), claudecode.nvim, bufferline, which-key, base16 (Black Metal theme), nvim-lspconfig + mason (pyright, ts_ls, lua_ls), render-markdown, and jupytext + molten for notebooks. Versions are pinned in `lazy-lock.json`.

## Requirements

- Neovim 0.11+
- git
- [Claude Code](https://claude.com/claude-code) (`claude` on PATH) for the Claude pane
- [opencode](https://opencode.ai) at `~/.opencode/bin/opencode` (optional)
- [WezTerm](https://wezterm.org), [Ghostty](https://ghostty.org) or another terminal with the kitty graphics protocol, for inline notebook plots (optional)
- [uv](https://docs.astral.sh/uv/) and `jupytext` for notebooks (optional)
- [Zig](https://ziglang.org) (`winget install zig.zig`) to build the Python / Dart treesitter parsers on first use (optional; without it those files use regex highlighting)

Paths assume Windows (`Scripts/python.exe` in venvs). On macOS/Linux the notebook parts need those paths changed to `bin/python`.

## Install

Back up your current config, then clone:

```sh
# Windows
git clone https://github.com/Nitride27/nvc "$env:LOCALAPPDATA\nvim"
# macOS / Linux
git clone https://github.com/Nitride27/nvc ~/.config/nvim
```

Start `nvim`; plugins install on first launch.

## Terminal

Configs for the terminal it runs in are in `terminal/`. Both use JetBrainsMono Nerd Font, the Black Metal theme and kitty graphics (for inline plots), and leave Alt+h/j/k/l free for Neovim.

- **WezTerm** (Windows): point WezTerm at the repo so it stays in sync. `nitride.ps1` is the banner shown in each new pane; delete the `default_prog` line to skip it.
  ```powershell
  [Environment]::SetEnvironmentVariable("WEZTERM_CONFIG_FILE", "$env:LOCALAPPDATA\nvim\terminal\wezterm\.wezterm.lua", "User")
  ```
- **Ghostty** (macOS / Linux): copy `terminal/ghostty/config` to `~/.config/ghostty/config`.

## License

MIT
