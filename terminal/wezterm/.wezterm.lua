-- Port of the old Ghostty setup (black-metal theme, big scrollback) to WezTerm on Windows.
local wezterm = require("wezterm")
local c = wezterm.config_builder()

-- Open maximized: the nvc layout (40-col tree + editor + 40% Claude) is cramped at the default 80 columns.
wezterm.on("gui-startup", function(cmd)
  local _, _, window = wezterm.mux.spawn_window(cmd or {})
  window:gui_window():maximize()
end)

-- -NoExit keeps the shell open after printing the NITRIDE banner.
c.default_prog = { "powershell.exe", "-NoLogo", "-NoExit", "-File", wezterm.home_dir .. "/.config/wezterm/nitride.ps1" }
c.font = wezterm.font("JetBrainsMono Nerd Font")
-- Default 12pt zoomed out one step (Ctrl+-), measured as a 13x29px cell at 144 dpi.
c.font_size = 12 / 1.1
c.scrollback_lines = 50000
c.enable_kitty_graphics = true
c.color_scheme = "Black Metal (base16)"
c.window_padding = { left = 12, right = 12, top = 10, bottom = 6 }
-- Alt+h/j/k/l belong to Neovim pane moves (nvc).
c.keys = {
  { key = "v", mods = "CTRL|SHIFT", action = wezterm.action.PasteFrom("Clipboard") },
}
return c
