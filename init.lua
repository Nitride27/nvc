-- Leader is backslash, so Space never waits for a shortcut while you write.
vim.g.mapleader = "\\"
vim.g.maplocalleader = "\\"

local o = vim.opt
o.number = true
o.relativenumber = false
o.mouse = "a"
o.clipboard = "unnamedplus"
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.smartindent = true
o.ignorecase = true
o.smartcase = true
o.signcolumn = "yes"
o.termguicolors = true
o.splitright = true
o.splitbelow = true
o.undofile = true
o.updatetime = 250
o.scrolloff = 8
o.completeopt = { "menuone", "noselect", "popup" }

-- Move between panes with Alt+h/j/k/l, even while typing in the editor, Claude or opencode.
for _, dir in ipairs({ "h", "j", "k", "l" }) do
  vim.keymap.set("n", "<A-" .. dir .. ">", "<C-w>" .. dir)
  vim.keymap.set({ "i", "t" }, "<A-" .. dir .. ">", "<C-\\><C-n><C-w>" .. dir)
end
-- Ghostty's Ctrl+Shift+V can paste a stale copy, so Ctrl+V reads the system clipboard directly.
-- In Claude's pane Ctrl+V pastes whatever was copied, text or image.
local function paste_clipboard()
  local text = vim.fn.getreg("+")
  if text ~= "" then vim.api.nvim_paste(text, true, -1) end
end

-- The first text or image format on the clipboard is what was copied (apps list their main format first).
local function clipboard_is_image()
  if jit.os ~= "Windows" then return vim.fn.getreg("+") == "" end
  local ffi = require("ffi")
  pcall(ffi.cdef, "int OpenClipboard(void*); int CloseClipboard(void); unsigned int EnumClipboardFormats(unsigned int);")
  local user32 = ffi.load("user32")
  if user32.OpenClipboard(nil) == 0 then return false end
  local f, image = user32.EnumClipboardFormats(0), false
  while f ~= 0 do
    if f == 1 or f == 13 then break end -- CF_TEXT, CF_UNICODETEXT
    if f == 2 or f == 8 or f == 17 then image = true break end -- CF_BITMAP, CF_DIB, CF_DIBV5
    f = user32.EnumClipboardFormats(f)
  end
  user32.CloseClipboard()
  return image
end
vim.keymap.set({ "n", "i", "c" }, "<C-v>", paste_clipboard, { desc = "Paste system clipboard" })

-- A terminal's command, from its "term://{cwd}//{pid}:{cmd}" name (the cwd alone could contain "claude").
local function term_cmd(buf) return (vim.api.nvim_buf_get_name(buf):match("//%d+:(.*)$") or ""):lower() end
local function is_ai_term(buf)
  return vim.bo[buf].buftype == "terminal" and (term_cmd(buf):find("claude") or term_cmd(buf):find("opencode")) ~= nil
end

vim.api.nvim_create_autocmd("TermOpen", {
  callback = function(ev)
    if not term_cmd(ev.buf):find("claude") then
      vim.keymap.set("t", "<C-v>", paste_clipboard, { buffer = ev.buf, desc = "Paste system clipboard" })
    else
      -- Alt+V (sent as Esc v) is Claude's image paste on Windows; Ctrl+V is its text paste.
      local function send(keys) vim.fn.chansend(vim.b[ev.buf].terminal_job_id, keys) end
      vim.keymap.set("t", "<C-v>", function() send(clipboard_is_image() and "\27v" or "\22") end,
        { buffer = ev.buf, desc = "Paste text or image into Claude" })
      vim.keymap.set("t", "<A-v>", function() send("\27v") end, { buffer = ev.buf, desc = "Paste image into Claude" })
    end
  end,
})

-- Unused remote-plugin hosts: skip probing for them at startup (Python stays for molten).
vim.g.loaded_perl_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_node_provider = 0

vim.keymap.set("n", "<Esc>", "<cmd>nohlsearch<cr>")
vim.keymap.set("n", "<leader>w", "<cmd>write<cr>", { desc = "Save" })
vim.keymap.set({ "n", "i" }, "<C-s>", "<cmd>write<cr>", { desc = "Save" })
vim.api.nvim_create_autocmd("TextYankPost", { callback = function() vim.hl.on_yank() end })

-- Reopen a file where you left it.
vim.api.nvim_create_autocmd("BufReadPost", {
  callback = function(ev)
    if vim.bo[ev.buf].filetype == "gitcommit" then return end
    local mark = vim.api.nvim_buf_get_mark(ev.buf, '"')
    if mark[1] > 0 and mark[1] <= vim.api.nvim_buf_line_count(ev.buf) then pcall(vim.api.nvim_win_set_cursor, 0, mark) end
  end,
})

-- Unsaved edits are saved when you leave the file or Neovim, so Claude / opencode always read what you see
-- (and never overwrite edits you hadn't saved yet).
vim.api.nvim_create_autocmd({ "BufLeave", "FocusLost" }, {
  callback = function(ev)
    local bo = vim.bo[ev.buf]
    if bo.buftype == "" and bo.modified and bo.modifiable and not bo.readonly and vim.api.nvim_buf_get_name(ev.buf) ~= "" then
      vim.api.nvim_buf_call(ev.buf, function() vim.cmd("silent! update") end)
    end
  end,
})
vim.keymap.set("n", "<leader>q", "<cmd>quit<cr>", { desc = "Quit window" })

-- Layout: file tree (left) · editor (middle, can be closed) · Claude / opencode (right).
local TREE_WIDTH = 40
local AI_WIDTH = 0.4
local function is_editor_win(win)
  if vim.api.nvim_win_get_config(win).relative ~= "" or vim.w[win].snacks_layout then return false end
  return vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function editor_wins()
  return vim.tbl_filter(is_editor_win, vim.api.nvim_tabpage_list_wins(0))
end

local last_editor_buf
vim.api.nvim_create_autocmd("BufEnter", {
  callback = function(ev)
    if vim.bo[ev.buf].buftype == "" and vim.api.nvim_buf_get_name(ev.buf) ~= "" then last_editor_buf = ev.buf end
  end,
})

-- Widths you set by dragging a border with the mouse are remembered per pane and reused on every toggle.
local tree_width, ai_widths = TREE_WIDTH, {}
local function ai_kind(buf) return term_cmd(buf):find("opencode") and "opencode" or "claude" end
-- Only resizes right after a mouse event count as yours; automatic ones (a pane closing) are ignored.
local last_mouse = 0
vim.on_key(function(_, typed)
  local key = typed and vim.fn.keytrans(typed) or ""
  if key:find("Mouse>") or key:find("Drag>") or key:find("Release>") then last_mouse = vim.uv.now() end
end)
vim.api.nvim_create_autocmd("WinResized", {
  callback = function()
    if vim.uv.now() - last_mouse > 500 then return end
    if #editor_wins() == 0 then return end -- without an editor the AI pane just fills the space
    for _, win in ipairs(vim.v.event.windows) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
        if vim.w[win].snacks_layout then
          tree_width = vim.api.nvim_win_get_width(win)
        elseif is_ai_term(vim.api.nvim_win_get_buf(win)) then
          ai_widths[ai_kind(vim.api.nvim_win_get_buf(win))] = vim.api.nvim_win_get_width(win)
        end
      end
    end
  end,
})

-- Tree keeps its width; the AI column keeps its dragged width beside an editor (AI_WIDTH until you drag it),
-- or takes all remaining space without one.
local function fix_widths(has_editor)
  local wins = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0))
  local ai = vim.tbl_filter(function(w) return is_ai_term(vim.api.nvim_win_get_buf(w)) end, wins)
  for _, win in ipairs(wins) do
    if vim.w[win].snacks_layout then vim.api.nvim_win_set_width(win, tree_width) end
  end
  if not has_editor then return end
  local done = {} -- panes stacked in one column share a width; set it once
  for _, win in ipairs(ai) do
    local col = vim.api.nvim_win_get_position(win)[2]
    if not done[col] then
      done[col] = true
      local kind = ai_kind(vim.api.nvim_win_get_buf(win))
      vim.api.nvim_win_set_width(win, ai_widths[kind] or ai_widths.claude or math.floor(vim.o.columns * AI_WIDTH))
    end
  end
end

-- The terminal window can grow after startup (WezTerm opens at 80 columns), so re-apply the layout widths.
vim.api.nvim_create_autocmd("VimResized", { callback = function() fix_widths(#editor_wins() > 0) end })

-- Returns an editor window, reopening one if the editor was closed.
local function ensure_editor()
  local wins = editor_wins()
  if #wins > 0 then return wins[1] end
  local buf = last_editor_buf and vim.api.nvim_buf_is_valid(last_editor_buf) and last_editor_buf
    or vim.api.nvim_create_buf(true, false)
  -- A full-height column right of the tree (or leftmost), never inside the Claude / opencode stack.
  local tree
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" and vim.w[win].snacks_layout then tree = win end
  end
  local win = tree and vim.api.nvim_open_win(buf, true, { split = "right", win = tree })
    or vim.api.nvim_open_win(buf, true, { split = "left", win = -1 })
  fix_widths(true)
  return win
end

local function toggle_editor()
  local wins = editor_wins()
  if #wins == 0 then return ensure_editor() end
  local non_float = vim.tbl_filter(function(w) return vim.api.nvim_win_get_config(w).relative == "" end, vim.api.nvim_tabpage_list_wins(0))
  if #non_float == #wins then return vim.notify("Open the tree or Claude first; the editor is the only window") end
  for _, win in ipairs(wins) do vim.api.nvim_win_close(win, false) end
  fix_widths(false)
end

local function toggle_tree() Snacks.explorer() end
-- The Claude bridge isn't started at launch (so `nvim` as $EDITOR stays light); start it on first use.
local function ensure_claude_bridge()
  if not require("claudecode").state.server then vim.cmd("ClaudeCodeStart") end
end
local function toggle_claude()
  ensure_claude_bridge()
  vim.cmd("ClaudeCode")
end
local function toggle_opencode()
  -- Stacks under Claude in the same column; drag the bar between them to change their heights.
  Snacks.terminal.toggle(vim.fs.normalize("~/.opencode/bin/opencode"), { win = { position = "right", wo = { winbar = "" } } })
  vim.schedule(function() fix_widths(#editor_wins() > 0) end)
end
-- A PowerShell under the editor (not across the tree / Claude), started in the project folder.
local function toggle_shell()
  Snacks.terminal.toggle("powershell.exe -NoLogo", {
    cwd = vim.fn.getcwd(),
    win = { position = "bottom", relative = "win", win = ensure_editor(), height = 0.3, wo = { winbar = "" } },
  })
end

-- Claude / opencode / shell: no title bar on top, just a named status bar at the bottom. That status bar
-- is the border you drag to change their heights (Neovim can't resize from a title bar).
vim.api.nvim_create_autocmd({ "TermOpen", "BufWinEnter", "WinEnter" }, {
  callback = function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].buftype == "terminal" and vim.api.nvim_win_get_config(win).relative == "" then
        local name = not is_ai_term(buf) and "Shell" or ai_kind(buf) == "opencode" and "opencode" or "Claude"
        vim.wo[win].winbar = ""
        vim.wo[win].statusline = "  " .. name .. "%=drag this bar to resize  "
      end
    end
  end,
})

-- Resize the current pane from anywhere (even while typing): Alt+Shift+arrows.
for key, cmd in pairs({ Up = "resize +2", Down = "resize -2", Right = "vertical resize +4", Left = "vertical resize -4" }) do
  vim.keymap.set({ "n", "i", "t" }, "<A-S-" .. key .. ">", function()
    last_mouse = vim.uv.now() -- counts as your own resize, so it is remembered
    vim.cmd(cmd)
  end, { desc = "Resize pane" })
end

-- File tabs: Alt+w closes the current file, Alt+. / Alt+, switch to the next / previous tab.
local function tab_cmd(cmd)
  return function()
    vim.cmd("stopinsert")
    local win = editor_wins()[1]
    if not win then return end
    vim.api.nvim_set_current_win(win)
    if cmd == "close" then Snacks.bufdelete() else vim.cmd(cmd) end
  end
end
vim.keymap.set({ "n", "i", "t" }, "<A-w>", tab_cmd("close"), { desc = "Close file tab" })
vim.keymap.set({ "n", "i", "t" }, "<A-.>", tab_cmd("BufferLineCycleNext"), { desc = "Next file tab" })
vim.keymap.set({ "n", "i", "t" }, "<A-,>", tab_cmd("BufferLineCyclePrev"), { desc = "Previous file tab" })

-- Rescan the tree and its git colours (Snacks only does that by itself when .git/index changes).
local function refresh_tree()
  for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do
    require("snacks.explorer.actions").actions.explorer_update(p)
  end
end

-- Edits made outside Neovim (Claude, opencode, git) reload open files and recolour the tree
-- when you come back to Neovim, leave a terminal, switch files or save.
local refresh_pending = false
vim.api.nvim_create_autocmd({ "FocusGained", "TermLeave", "BufEnter", "BufWritePost" }, {
  callback = function(ev)
    if ev.event == "BufEnter" and vim.bo[ev.buf].buftype ~= "" then return end
    if vim.fn.getcmdwintype() == "" then vim.cmd("silent! checktime") end
    if refresh_pending then return end
    refresh_pending = true
    vim.defer_fn(function()
      refresh_pending = false
      refresh_tree()
    end, 200)
  end,
})

-- Edits that happen while you sit in another pane (Claude writing files) fire none of the events
-- above, so the project folder is watched (one OS-level recursive watch, no polling) and open files /
-- the tree refresh 300 ms after the last change. Inside .git only index / HEAD matter (stage, commit, checkout).
-- Only in the IDE layout; `ide_active` also marks that session for saving.
local ide_active, watcher = false, nil
local watch_debounce = vim.uv.new_timer()
local function start_watching()
  if watcher then watcher:close() end
  watcher = vim.uv.new_fs_event()
  watcher:start(vim.fn.getcwd(), { recursive = true }, function(err, file)
    if err then return end
    file = (file or ""):gsub("\\", "/")
    if file:match("^%.git/") and file ~= ".git/index" and file ~= ".git/HEAD" then return end
    watch_debounce:start(300, 0, vim.schedule_wrap(function()
      vim.cmd("silent! checktime")
      refresh_tree()
    end))
  end)
end
vim.api.nvim_create_autocmd("DirChanged", { callback = function() if ide_active then start_watching() end end })

-- New file / folder anywhere, like VS Code: Alt+n / Alt+Shift+n, :NewFile / :NewFolder, or right-click.
-- The prompt starts in the folder under the tree cursor (else the current file's folder) and takes any
-- path: edit it, or type ~/... or /...; missing parent folders are created. A path ending in "/" is a folder.
local function new_path(kind)
  local base = vim.fn.getcwd()
  local tree = Snacks.picker.get({ source = "explorer" })[1]
  if tree and vim.bo.filetype == "snacks_picker_list" then
    base = tree:dir()
  elseif vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" then
    base = vim.fn.expand("%:p:h")
  end
  Snacks.input({ prompt = "New " .. kind, default = base .. "/", completion = "file" }, function(value)
    value = vim.trim(value or "")
    if value == "" then return end
    local path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(value), ":p"))
    if kind == "folder" or value:sub(-1) == "/" then
      vim.fn.mkdir(path, "p")
    else
      if vim.uv.fs_stat(path) then return vim.notify("Already exists: " .. path, vim.log.levels.WARN) end
      vim.fn.mkdir(vim.fs.dirname(path), "p")
      vim.fn.writefile({}, path)
      vim.api.nvim_set_current_win(ensure_editor())
      vim.cmd.edit(vim.fn.fnameescape(path))
    end
    if tree and vim.startswith(path, tree:cwd() .. "/") then Snacks.explorer.reveal({ file = path }) end
    refresh_tree()
  end)
end
vim.api.nvim_create_user_command("NewFile", function() new_path("file") end, { desc = "New file (any path)" })
vim.api.nvim_create_user_command("NewFolder", function() new_path("folder") end, { desc = "New folder (any path)" })
for key, kind in pairs({ ["<A-n>"] = "file", ["<A-N>"] = "folder" }) do
  vim.keymap.set({ "n", "i", "t" }, key, function()
    vim.cmd("stopinsert")
    new_path(kind)
  end, { desc = "New " .. kind })
end
vim.cmd([[
  amenu PopUp.-newsep- <Nop>
  amenu PopUp.New\ File <Cmd>NewFile<CR>
  amenu PopUp.New\ Folder <Cmd>NewFolder<CR>
]])

-- Alt versions work in every mode, including while typing in the editor, Claude or opencode.
for key, fn in pairs({ c = toggle_claude, e = toggle_editor, v = toggle_tree, o = toggle_opencode, t = toggle_shell }) do
  vim.keymap.set({ "n", "i", "t" }, "<A-" .. key .. ">", function()
    vim.cmd("stopinsert")
    fn()
  end)
end

-- Per-folder sessions: the files open in a folder come back the next time you open it.
local SESSIONS = vim.fn.stdpath("state") .. "/sessions"
local function session_file(dir) return SESSIONS .. "/" .. vim.fs.normalize(dir):lower():gsub("[^%w]+", "_") end

local function save_session()
  local cwd = vim.fs.normalize(vim.fn.getcwd())
  local cur_buf = last_editor_buf and vim.api.nvim_buf_is_valid(last_editor_buf) and last_editor_buf or 0
  local files, current = {}, vim.fs.normalize(vim.api.nvim_buf_get_name(cur_buf))
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and name ~= current
      and vim.startswith(name:lower(), cwd:lower() .. "/") and vim.uv.fs_stat(name) then
      files[#files + 1] = name
    end
  end
  if vim.startswith(current:lower(), cwd:lower() .. "/") and vim.uv.fs_stat(current) then files[#files + 1] = current end
  if #files == 0 then return end -- keep the old session rather than wiping it with nothing
  vim.fn.mkdir(SESSIONS, "p")
  vim.fn.writefile(files, session_file(cwd))
end

-- The last file in the list was the one you were on.
local function restore_session()
  local f = session_file(vim.fn.getcwd())
  if vim.fn.filereadable(f) == 0 then return end
  local files = vim.tbl_filter(function(p) return vim.uv.fs_stat(p) ~= nil end, vim.fn.readfile(f))
  if #files == 0 then return end
  vim.api.nvim_set_current_win(ensure_editor())
  for _, p in ipairs(files) do vim.cmd.badd(vim.fn.fnameescape(p)) end
  vim.cmd.edit(vim.fn.fnameescape(files[#files]))
end

local function start_workspace(restore)
  if not ide_active then
    ide_active = true
    start_watching()
  end
  if restore then restore_session() end
  Snacks.explorer()
  toggle_claude()
  local win = editor_wins()[1]
  if win then vim.api.nvim_set_current_win(win) end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if not ide_active then return end
    save_session()
    if watcher then watcher:close() end
  end,
})

-- Switch the whole workspace, like VS Code's Open Folder: tree, Claude and opencode restart in `dir`.
local function open_folder(dir)
  dir = vim.fn.fnamemodify(vim.fn.expand(dir), ":p"):gsub("[/\\]$", "")
  if vim.fn.isdirectory(dir) == 0 then return vim.notify("Not a folder: " .. dir, vim.log.levels.ERROR) end
  if ide_active then save_session() end
  for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do p:close() end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buftype == "terminal" then
      pcall(vim.fn.jobstop, vim.b[buf].terminal_job_id)
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  -- Close the old project's unchanged files, like VS Code does, so their language servers can shut down.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    if vim.bo[buf].buftype == "" and not vim.bo[buf].modified and not vim.startswith(name:lower(), vim.fs.normalize(dir):lower() .. "/") then
      pcall(vim.api.nvim_buf_delete, buf, {})
    end
  end
  vim.cmd.cd(dir)
  if require("claudecode").state.server then vim.cmd("ClaudeCodeStop") end -- restart it so it advertises the new folder
  start_workspace(true)
  vim.notify("Opened " .. dir)
end

-- Folder picker: recently opened folders first, then every folder in PROJECTS_DIR.
local PROJECTS_DIR = "D:/Codes"
local RECENT_FILE = vim.fn.stdpath("state") .. "/recent_folders"
local MAX_RECENT = 20

vim.api.nvim_create_autocmd("DirChanged", {
  callback = function()
    local dir = vim.fn.getcwd()
    local list = { dir }
    for _, d in ipairs(vim.fn.filereadable(RECENT_FILE) == 1 and vim.fn.readfile(RECENT_FILE) or {}) do
      if d ~= dir and #list < MAX_RECENT then list[#list + 1] = d end
    end
    vim.fn.writefile(list, RECENT_FILE)
  end,
})

-- Asks for a path (Tab completes, any drive works) and hands it to `fn`.
local function ask_path(prompt, default, completion, fn)
  Snacks.input({ prompt = prompt, default = default, completion = completion }, function(value)
    value = vim.trim(value or "")
    if value ~= "" then fn(vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(value), ":p"))) end
  end)
end

-- Opens `dir` as the workspace, offering to create it first if it doesn't exist.
local function open_or_create_folder(dir)
  dir = dir:gsub("/$", "")
  if vim.fn.isdirectory(dir) == 0 then
    if vim.fn.filereadable(dir) == 1 then return vim.notify("That's a file: " .. dir, vim.log.levels.ERROR) end
    if vim.fn.confirm("Create " .. dir .. "?", "&Yes\n&No") ~= 1 then return end
    vim.fn.mkdir(dir, "p")
  end
  open_folder(dir)
end

local function pick_actions()
  local home = vim.fs.normalize(vim.env.HOME)
  return {
    { text = "Browse any folder…", action = function()
      ask_path("Open folder", vim.fs.normalize(vim.fn.getcwd()) .. "/", "dir", open_or_create_folder)
    end },
    { text = "New folder…", action = function()
      ask_path("New folder", PROJECTS_DIR .. "/", "dir", open_or_create_folder)
    end },
    { text = "New file…", action = function()
      ask_path("New file", PROJECTS_DIR .. "/", "file", function(path)
        if vim.fn.isdirectory(path) == 1 then return open_folder(path) end
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        if not vim.uv.fs_stat(path) then vim.fn.writefile({}, path) end
        open_folder(vim.fs.dirname(path))
        vim.api.nvim_set_current_win(ensure_editor())
        vim.cmd.edit(vim.fn.fnameescape(path))
      end)
    end },
    { text = "Home (" .. home .. ")", action = function() open_folder(home) end },
  }
end

local function pick_folder()
  local items, seen = pick_actions(), {}
  local function add(dir)
    if not seen[dir] and vim.fn.isdirectory(dir) == 1 then
      seen[dir] = true
      items[#items + 1] = { text = dir, file = dir, dir = true }
    end
  end
  for _, d in ipairs(vim.fn.filereadable(RECENT_FILE) == 1 and vim.fn.readfile(RECENT_FILE) or {}) do add(d) end
  local subdirs = {}
  for name, kind in vim.fs.dir(PROJECTS_DIR) do
    if kind == "directory" and not name:match("^[%._]") then subdirs[#subdirs + 1] = PROJECTS_DIR .. "/" .. name end
  end
  table.sort(subdirs, function(a, b) return a:lower() < b:lower() end)
  for _, d in ipairs(subdirs) do add(d) end
  Snacks.picker.pick({
    title = "Open folder  (or type any path and press Enter)",
    items = items,
    format = function(item, picker)
      if item.action then return { { "  " .. item.text, "Special" } } end
      return Snacks.picker.format.file(item, picker)
    end,
    preview = "none",
    layout = { preset = "select" },
    confirm = function(picker, item)
      local typed = vim.trim(picker.input:get())
      picker:close()
      -- A typed path that matches nothing in the list (e.g. E:/stuff, ~/notes) opens or creates that folder.
      if not item and typed ~= "" then
        return open_or_create_folder(vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(typed), ":p")))
      end
      if not item then return end
      if item.action then return vim.schedule(item.action) end
      open_folder(item.file)
    end,
  })
end

vim.api.nvim_create_user_command("OpenFolder", function(cmd)
  if cmd.args == "" then return pick_folder() end
  open_folder(cmd.args)
end, { nargs = "?", complete = "dir", desc = "Open a folder as the workspace" })
vim.keymap.set({ "n", "i", "t" }, "<A-f>", function()
  vim.cmd("stopinsert")
  pick_folder()
end, { desc = "Open folder" })

-- In $HOME, choose a project first instead of starting Claude in the home folder.
vim.api.nvim_create_user_command("IDE", function()
  if vim.fn.getcwd() == vim.env.HOME then return pick_folder() end
  start_workspace(vim.fn.argc() == 0) -- `nvc file.py` opens just that file; plain `nvc` brings back the last files
end, { desc = "Open tree + editor + Claude" })

-- VS Code's git colours for file names in the tree (the theme's defaults are near-invisible on black).
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    for group, fg in pairs({
      Modified = "#e2c08d", Staged = "#e2c08d", Added = "#73c991", Untracked = "#73c991", Renamed = "#73c991",
      Deleted = "#c74e39", Unmerged = "#e4676b", Ignored = "#8c8c8c",
    }) do
      vim.api.nvim_set_hl(0, "SnacksPickerGitStatus" .. group, { fg = fg })
    end
  end,
})

-- Python for Neovim's notebook bridge (pynvim + jupyter_client), kept in its own uv env.
vim.g.python3_host_prog = vim.fn.stdpath("data") .. "/molten-host/Scripts/python.exe"

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", "https://github.com/folke/lazy.nvim.git", lazypath })
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
  {
    -- Same base16 "Black Metal" palette as the Ghostty theme.
    "RRethy/base16-nvim",
    priority = 1000,
    config = function() vim.cmd.colorscheme("base16-black-metal") end,
  },
  { "folke/which-key.nvim", event = "VeryLazy", opts = {} },
  {
    "folke/snacks.nvim",
    priority = 900,
    lazy = false,
    opts = {
      explorer = {},
      bigfile = {}, -- files over 1.5 MB (big JSON, logs) open without LSP / treesitter / syntax
      image = {}, -- inline images (notebook plots) via Ghostty's graphics protocol
      terminal = {},
      input = {},
      notifier = {},
      picker = {
        sources = {
          files = { hidden = true, ignored = true },
          grep = { hidden = true, ignored = true },
          explorer = {
            git_status_open = true, -- colour folders that contain changes, like VS Code
            ignored = true, -- show git-ignored files (CLAUDE.md, graphify-out/, ...); toggle with I
            hidden = true, -- show dotfiles too; toggle with H
            actions = {
              open_as_workspace = function(_, item)
                if item then open_folder(item.dir and item.file or vim.fn.fnamemodify(item.file, ":h")) end
              end,
              -- Open files in the editor pane, recreating it if closed, so they never replace the AI terminal.
              open_in_editor = function(picker, item, action)
                if item and not item.dir then picker.main = ensure_editor() end
                return require("snacks.explorer.actions").actions.confirm(picker, item, action)
              end,
            },
            win = { list = { keys = { ["<CR>"] = "open_in_editor", ["l"] = "open_in_editor", ["<2-LeftMouse>"] = "open_in_editor", ["O"] = "open_as_workspace" } } },
          },
        },
      },
    },
    keys = {
      { "<leader>e", toggle_editor, desc = "Show / hide editor" },
      { "<leader>o", toggle_opencode, desc = "Show / hide opencode" },
      { "<leader>ff", function() Snacks.picker.files() end, desc = "Find files" },
      { "<leader>p", pick_folder, desc = "Open folder" },
      { "<leader>/", function() Snacks.picker.grep() end, desc = "Search text" },
      { "<leader>fb", function() Snacks.picker.buffers() end, desc = "Buffers" },
      { "<leader>fr", function() Snacks.picker.recent() end, desc = "Recent files" },
      { "<leader>v", toggle_tree, desc = "Show / hide tree" },
      { "<leader>t", toggle_shell, desc = "Show / hide shell" },
      { "<C-p>", function() Snacks.picker.smart() end, desc = "Go to file" },
      { "<leader>g", nil, desc = "Git" },
      { "<leader>gs", function() Snacks.picker.git_status() end, desc = "Changed files" },
      { "<leader>gd", function() Snacks.picker.git_diff() end, desc = "Changed lines (hunks)" },
      { "<leader>gl", function() Snacks.picker.git_log_file() end, desc = "History of this file" },
      { "<leader>gb", function() Snacks.git.blame_line() end, desc = "Blame this line" },
      { "<leader>go", function() Snacks.gitbrowse() end, desc = "Open on GitHub" },
      { "<leader>x", function() Snacks.picker.diagnostics() end, desc = "Problems (all files)" },
      { "<leader>ls", function() Snacks.picker.lsp_symbols() end, desc = "Symbols in file" },
      { "<leader>lS", function() Snacks.picker.lsp_workspace_symbols() end, desc = "Symbols in project" },
      { "<leader>u", function() Snacks.picker.undo() end, desc = "Undo history" },
    },
  },
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    lazy = false,
    opts = {
      terminal_cmd = vim.fs.normalize("~/.local/bin/claude.exe"), -- forward slashes: the cmd string is shell-split
      auto_start = false, -- started by the IDE layout / Alt+c, not by every `nvim` (git commit, $EDITOR)
      log_level = "warn", -- no "integration stopped" line printed on quit
      terminal = { split_side = "right", split_width_percentage = AI_WIDTH, snacks_win_opts = { wo = { winbar = "" } } },
    },
    keys = {
      { "<leader>a", nil, desc = "Claude" },
      { "<leader>c", toggle_claude, desc = "Show / hide Claude" },
      { "<leader>af", function() ensure_claude_bridge() vim.cmd("ClaudeCodeFocus") end, desc = "Focus Claude" },
      { "<leader>ar", function() ensure_claude_bridge() vim.cmd("ClaudeCode --resume") end, desc = "Resume a session" },
      { "<leader>aC", function() ensure_claude_bridge() vim.cmd("ClaudeCode --continue") end, desc = "Continue last session" },
      { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select model" },
      { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add current file" },
      { "<leader>as", "<cmd>ClaudeCodeSend<cr>", mode = "v", desc = "Send selection" },
      { "<leader>as", "<cmd>ClaudeCodeTreeAdd<cr>", desc = "Add file from tree", ft = { "snacks_picker_list" } },
      { "<leader>aa", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept diff" },
      { "<leader>ad", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Reject diff" },
    },
  },
  {
    -- VS Code-style file tabs: click to switch, x / middle-click to close. Claude and opencode never appear here.
    "akinsho/bufferline.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    lazy = false,
    opts = {
      options = {
        close_command = function(buf) Snacks.bufdelete(buf) end,
        middle_mouse_command = function(buf) Snacks.bufdelete(buf) end,
        custom_filter = function(buf) return vim.bo[buf].buftype == "" end,
        offsets = { { filetype = "snacks_layout_box", text = "Explorer", separator = true } },
        always_show_bufferline = true,
      },
    },
  },
  {
    -- Opens .ipynb as editable Python cells (# %%) and writes back to the notebook on save, keeping outputs.
    "GCBallesteros/jupytext.nvim",
    lazy = false,
    opts = { style = "percent", output_extension = "auto", force_ft = nil },
  },
  {
    -- Runs notebook cells in a Jupyter kernel and shows the output (and plots) under each cell.
    "benlubas/molten-nvim",
    branch = "main", -- the tagged releases predate the snacks.nvim image provider
    build = ":UpdateRemotePlugins",
    lazy = false,
    init = function()
      vim.g.molten_image_provider = "snacks.nvim"
      vim.g.molten_virt_text_output = true
      vim.g.molten_virt_lines_off_by_1 = true
      vim.g.molten_output_win_max_height = 20
      vim.g.molten_wrap_output = true
      vim.g.molten_auto_open_output = false
    end,
  },
  {
    -- Renders .md as formatted text (headings, lists, checkboxes, tables, code blocks); the line you edit stays raw.
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    opts = { completions = { lsp = { enabled = false } } },
    init = function()
      vim.api.nvim_create_autocmd("FileType", {
        pattern = "markdown",
        callback = function(ev)
          vim.keymap.set("n", "<leader>m", "<cmd>RenderMarkdown toggle<cr>", { buffer = ev.buf, desc = "Markdown: formatted / raw" })
        end,
      })
    end,
  },
  -- Never loaded: only its pinned grammar versions and highlight queries are used (see TS_LANGS below).
  { "nvim-treesitter/nvim-treesitter", branch = "main", lazy = true },
  { "neovim/nvim-lspconfig", lazy = true },
  { "mason-org/mason.nvim", cmd = { "Mason", "MasonInstall", "MasonUpdate", "MasonUninstall" }, opts = {} },
  {
    -- Loaded with the first file, so the tree / Claude / picker never wait on LSP setup.
    "mason-org/mason-lspconfig.nvim",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = { "mason-org/mason.nvim", "neovim/nvim-lspconfig" },
    opts = { ensure_installed = { "pyright", "ruff", "ts_ls", "lua_ls" } },
  },
}, {
  rocks = { enabled = false },
  change_detection = { notify = false },
  -- Built-in plugins this setup never uses (Snacks' explorer replaces netrw).
  performance = { rtp = { disabled_plugins = { "gzip", "tarPlugin", "zipPlugin", "tohtml", "tutor", "netrwPlugin" } } },
})

-- Treesitter highlighting for languages Neovim doesn't ship a parser for. nvim-treesitter supplies the pinned
-- grammar version and highlight queries; the parser is compiled with Zig (winget install zig.zig) the first
-- time a file of that language opens. :TSBuild <lang> rebuilds it (restart first: Windows locks a loaded parser).
local TS_LANGS = { "python", "dart" }
local TS_SITE = vim.fn.stdpath("data") .. "/site"
vim.opt.rtp:prepend(TS_SITE)
local ts_building = {}

local function ts_build(lang, on_done)
  if ts_building[lang] then return end
  if vim.fn.executable("zig") == 0 then
    return vim.notify("Install Zig (winget install zig.zig) to build the " .. lang .. " parser", vim.log.levels.WARN)
  end
  local ts_dir = require("lazy.core.config").plugins["nvim-treesitter"].dir
  local info = dofile(ts_dir .. "/lua/nvim-treesitter/parsers.lua")[lang].install_info
  local src = vim.fn.stdpath("cache") .. "/tree-sitter-" .. lang
  local root = src .. (info.location and "/" .. info.location or "")
  ts_building[lang] = true
  vim.fn.delete(src, "rf")
  vim.fn.mkdir(src, "p")
  vim.notify("Building the " .. lang .. " treesitter parser…")
  local function fail(msg)
    ts_building[lang] = nil
    vim.notify("Treesitter " .. lang .. ": " .. msg, vim.log.levels.ERROR)
  end
  local steps = {
    function() return { "git", "init", "-q" } end,
    function() return { "git", "fetch", "-q", "--depth", "1", info.url, info.revision } end,
    function() return { "git", "checkout", "-q", "FETCH_HEAD" } end,
    function()
      -- Built inside the clone so zig's .lib / .pdb side files never land next to the parser.
      local cmd = { "zig", "cc", "-shared", "-O2", "-I", root .. "/src", "-o", root .. "/parser.dll", root .. "/src/parser.c" }
      if vim.uv.fs_stat(root .. "/src/scanner.c") then cmd[#cmd + 1] = root .. "/src/scanner.c" end
      return cmd
    end,
  }
  local function run(i)
    if i > #steps then
      vim.fn.mkdir(TS_SITE .. "/parser", "p")
      local ok, err = vim.uv.fs_copyfile(root .. "/parser.dll", TS_SITE .. "/parser/" .. lang .. ".dll")
      if not ok then return fail(err) end
      local qdst = TS_SITE .. "/queries/" .. lang
      vim.fn.mkdir(qdst, "p")
      for name in vim.fs.dir(ts_dir .. "/runtime/queries/" .. lang) do
        vim.uv.fs_copyfile(ts_dir .. "/runtime/queries/" .. lang .. "/" .. name, qdst .. "/" .. name)
      end
      ts_building[lang] = nil
      vim.notify("Treesitter " .. lang .. " parser ready")
      return on_done and on_done()
    end
    vim.system(steps[i](), { cwd = src }, vim.schedule_wrap(function(r)
      if r.code ~= 0 then return fail(r.stderr) end
      run(i + 1)
    end))
  end
  run(1)
end

local function ts_start_all(lang)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype == lang then pcall(vim.treesitter.start, buf, lang) end
  end
end

vim.api.nvim_create_autocmd("FileType", {
  pattern = TS_LANGS,
  callback = function(ev)
    if not pcall(vim.treesitter.start, ev.buf, ev.match) then ts_build(ev.match, function() ts_start_all(ev.match) end) end
  end,
})
vim.api.nvim_create_user_command("TSBuild", function(cmd)
  ts_build(cmd.args, function() ts_start_all(cmd.args) end)
end, { nargs = 1, complete = function() return TS_LANGS end, desc = "Build a treesitter parser with Zig" })

vim.lsp.config("lua_ls", { settings = { Lua = { diagnostics = { globals = { "vim", "Snacks" } } } } })
-- Python: pyright checks types, ruff lints / formats / sorts imports.
vim.lsp.config("pyright", { settings = { pyright = { disableOrganizeImports = true } } })
-- Dart / Flutter's own language server, once the SDK is on PATH.
if vim.fn.executable("dart") == 1 then vim.lsp.enable("dartls") end
vim.diagnostic.config({ virtual_text = true, severity_sort = true })

-- Format on save (autosave included) with formatters every project of that language uses. lua_ls / ts_ls are
-- left out: they'd restyle whole existing files. \lf still formats with any server; :FormatToggle turns this off.
local FORMAT_ON_SAVE = { ruff = true, dartls = true }
vim.api.nvim_create_autocmd("BufWritePre", {
  callback = function(ev)
    if vim.g.format_on_save == false then return end
    if #vim.lsp.get_clients({ bufnr = ev.buf, method = "textDocument/formatting" }) == 0 then return end
    vim.lsp.buf.format({ bufnr = ev.buf, timeout_ms = 1000, filter = function(c) return FORMAT_ON_SAVE[c.name] end })
  end,
})
vim.api.nvim_create_user_command("FormatToggle", function()
  vim.g.format_on_save = vim.g.format_on_save == false
  vim.notify("Format on save " .. (vim.g.format_on_save and "on" or "off"))
end, { desc = "Turn format on save on / off" })

-- Completion menu: Tab / Shift+Tab move through it (or jump between snippet fields), Enter accepts a choice.
vim.keymap.set({ "i", "s" }, "<Tab>", function()
  if vim.fn.pumvisible() == 1 then return "<C-n>" end
  if vim.snippet.active({ direction = 1 }) then return "<Cmd>lua vim.snippet.jump(1)<CR>" end
  return "<Tab>"
end, { expr = true, desc = "Next completion / snippet field" })
vim.keymap.set({ "i", "s" }, "<S-Tab>", function()
  if vim.fn.pumvisible() == 1 then return "<C-p>" end
  if vim.snippet.active({ direction = -1 }) then return "<Cmd>lua vim.snippet.jump(-1)<CR>" end
  return "<S-Tab>"
end, { expr = true, desc = "Previous completion / snippet field" })
vim.keymap.set("i", "<CR>", function()
  if vim.fn.pumvisible() == 1 and vim.fn.complete_info({ "selected" }).selected ~= -1 then return "<C-y>" end
  return "<CR>"
end, { expr = true, desc = "Accept completion or new line" })

vim.api.nvim_create_autocmd("LspAttach", {
  callback = function(ev)
    local client = vim.lsp.get_client_by_id(ev.data.client_id)
    if client and client:supports_method("textDocument/completion") then
      vim.lsp.completion.enable(true, client.id, ev.buf, { autotrigger = true })
    end
    if client and client.name == "ruff" then client.server_capabilities.hoverProvider = false end -- pyright's hover is richer
    local map = function(lhs, rhs, desc) vim.keymap.set("n", lhs, rhs, { buffer = ev.buf, desc = desc }) end
    map("gd", vim.lsp.buf.definition, "Go to definition")
    map("<leader>la", vim.lsp.buf.code_action, "Code action")
    map("<leader>lf", function() vim.lsp.buf.format({ async = true }) end, "Format file")
  end,
})

-- Language servers keep running after their files close (pyright alone can hold 0.5-1 GB): stop one a
-- minute after its last file is closed. The next file of that language starts it again.
vim.api.nvim_create_autocmd("LspDetach", {
  callback = function(ev)
    local id = ev.data.client_id
    vim.defer_fn(function()
      local client = vim.lsp.get_client_by_id(id)
      if client and vim.tbl_isempty(client.attached_buffers) then client:stop() end
    end, 60000)
  end,
})

-- Stop Claude / opencode / shell jobs on quit so a lingering terminal process can't hold Neovim open.
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local job = vim.bo[buf].buftype == "terminal" and vim.b[buf].terminal_job_id
      if job then pcall(vim.fn.jobstop, job) end
    end
  end,
})

-- Notebooks (.ipynb open as Python with "# %%" cell markers).
local NOTEBOOK_ENVS = "D:/.nvim-notebooks" -- kernels and uv cache live on D: to keep C: free
local CELL = "^# %%%%"

local function cell_bounds(line)
  local last = vim.fn.line("$")
  local s = line
  while s > 1 and not vim.fn.getline(s):match(CELL) do s = s - 1 end
  if not vim.fn.getline(s):match(CELL) then return nil end -- above the first cell (jupytext header)
  local e = line + 1
  while e <= last and not vim.fn.getline(e):match(CELL) do e = e + 1 end
  return s, e - 1, vim.fn.getline(s):match("%[markdown%]") ~= nil
end

-- A project's own kernel if registered (see :NotebookKernel), else the shared default.
local function kernel_name()
  local name = vim.fn.fnamemodify(vim.fn.getcwd(), ":t"):lower():gsub("[^%w]+", "-")
  local spec = vim.fn.expand("$APPDATA/jupyter/kernels/" .. name)
  return vim.fn.isdirectory(spec) == 1 and name or "python3"
end

-- Starts a kernel if needed and runs `fn` once it is ready (code sent earlier would be lost).
local function with_kernel(fn)
  local ok, running = pcall(vim.fn.MoltenRunningKernels, true)
  if ok and #running > 0 then return fn() end
  vim.api.nvim_create_autocmd("User", { pattern = "MoltenKernelReady", once = true, callback = function() vim.schedule(fn) end })
  vim.cmd("MoltenInit " .. kernel_name())
end

local function run_cell(line)
  local s, e, markdown = cell_bounds(line)
  if not s then return nil end
  if not markdown and e > s then
    with_kernel(function() vim.fn.MoltenEvaluateRange(s + 1, e) end)
  end
  return e
end

local function run_cell_and_next()
  vim.cmd("stopinsert")
  local e = run_cell(vim.fn.line("."))
  if e and e < vim.fn.line("$") then vim.api.nvim_win_set_cursor(0, { math.min(e + 2, vim.fn.line("$")), 0 }) end
end

local function run_all()
  with_kernel(function()
    local line = 1
    while line <= vim.fn.line("$") do
      if vim.fn.getline(line):match(CELL) then line = (run_cell(line) or line) + 1 else line = line + 1 end
    end
  end)
end

local function new_cell()
  local _, e = cell_bounds(vim.fn.line("."))
  e = e or vim.fn.line("$")
  vim.api.nvim_buf_set_lines(0, e, e, false, { "", "# %%", "" })
  vim.api.nvim_win_set_cursor(0, { e + 3, 0 })
  vim.cmd("startinsert")
end

vim.api.nvim_create_autocmd("BufEnter", {
  pattern = "*.ipynb",
  callback = function(ev)
    local map = function(modes, lhs, rhs, desc) vim.keymap.set(modes, lhs, rhs, { buffer = ev.buf, desc = desc }) end
    map({ "n", "i" }, "<A-CR>", run_cell_and_next, "Run cell, go to next")
    map("n", "<leader>na", run_all, "Run all cells")
    map("n", "<leader>nn", new_cell, "New cell below")
    map("n", "<leader>no", "<cmd>noautocmd MoltenEnterOutput<cr>", "Open output (scroll / copy)")
    map("n", "<leader>nd", "<cmd>MoltenDelete<cr>", "Clear cell output")
    map("n", "<leader>nr", "<cmd>MoltenRestart!<cr>", "Restart kernel")
    map("n", "<leader>nk", "<cmd>MoltenInit<cr>", "Choose kernel")
  end,
})

-- Closing a notebook shuts down its kernel (one with torch loaded holds GBs). Outputs are saved on write.
vim.api.nvim_create_autocmd("BufDelete", {
  pattern = "*.ipynb",
  callback = function(ev)
    vim.api.nvim_buf_call(ev.buf, function() pcall(vim.cmd, "MoltenDeinit") end)
  end,
})

-- Keep outputs from runs in the .ipynb when saving.
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.ipynb",
  callback = function()
    local ok, running = pcall(vim.fn.MoltenRunningKernels, true)
    if ok and #running > 0 then pcall(vim.cmd, "MoltenExportOutput!") end
  end,
})

-- Turn the current project's own .venv / venv into a Jupyter kernel so notebooks see its libraries.
vim.api.nvim_create_user_command("NotebookKernel", function()
  local root = vim.fn.getcwd()
  local py
  for _, d in ipairs({ ".venv", "venv", "env" }) do
    if vim.fn.executable(root .. "/" .. d .. "/Scripts/python.exe") == 1 then py = root .. "/" .. d .. "/Scripts/python.exe" break end
  end
  if not py then return vim.notify("No .venv / venv in " .. root .. "; notebooks use the default kernel", vim.log.levels.WARN) end
  local name = vim.fn.fnamemodify(root, ":t"):lower():gsub("[^%w]+", "-")
  vim.notify("Adding ipykernel to " .. py .. " …")
  vim.system({ "uv", "pip", "install", "--python", py, "ipykernel" }, { env = { UV_CACHE_DIR = NOTEBOOK_ENVS .. "/uv-cache" } }, function(r)
    if r.code ~= 0 then return vim.schedule(function() vim.notify(r.stderr, vim.log.levels.ERROR) end) end
    vim.system({ py, "-m", "ipykernel", "install", "--user", "--name", name, "--display-name", name }, {}, function(r2)
      vim.schedule(function()
        if r2.code ~= 0 then return vim.notify(r2.stderr, vim.log.levels.ERROR) end
        vim.notify("Kernel '" .. name .. "' ready; notebooks in this project will use it")
      end)
    end)
  end)
end, { desc = "Use this project's venv as the notebook kernel" })

-- Notebook look: a divider per cell ("In [n]" / "Markdown"), markdown shown without its "# " prefix,
-- the jupytext metadata header folded away, and saved outputs loaded on open.
local nb_ns = vim.api.nvim_create_namespace("notebook_cells")

local function decorate(buf)
  vim.api.nvim_buf_clear_namespace(buf, nb_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local width = vim.o.columns
  local n, markdown = 0, false
  for i, line in ipairs(lines) do
    if line:match(CELL) then
      markdown = line:match("%[markdown%]") ~= nil
      if not markdown then n = n + 1 end
      local label = markdown and " Markdown " or (" In [" .. n .. "] ")
      vim.api.nvim_buf_set_extmark(buf, nb_ns, i - 1, 0, {
        virt_text = { { "━━" .. label .. string.rep("━", width), markdown and "Special" or "Title" } },
        virt_text_pos = "overlay",
        virt_lines = i > 1 and { { { "" } } } or nil, -- blank line between cells
        virt_lines_above = true,
      })
    elseif markdown and line:match("^# ?") then
      local prefix = #line:match("^# ?")
      vim.api.nvim_buf_set_extmark(buf, nb_ns, i - 1, 0, { end_col = prefix, conceal = "" })
      vim.api.nvim_buf_set_extmark(buf, nb_ns, i - 1, prefix, { end_col = #line, hl_group = line:match("^# #") and "Title" or "Normal" })
    end
  end
end

local function fold_header(win, buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, 40, false)
  if lines[1] ~= "# ---" then return end
  for i = 2, #lines do
    if lines[i] == "# ---" then
      vim.api.nvim_win_call(win, function()
        vim.wo.foldmethod = "manual"
        vim.wo.foldenable = true
        vim.wo.foldtext = "'  notebook metadata (za to show)'"
        vim.cmd("silent! normal! zE")
        vim.cmd(("silent! 1,%dfold"):format(i))
      end)
      return
    end
  end
end

vim.api.nvim_create_autocmd("BufWinEnter", {
  pattern = "*.ipynb",
  callback = function(ev)
    vim.wo.conceallevel = 2
    vim.wo.concealcursor = "nc"
    fold_header(vim.api.nvim_get_current_win(), ev.buf)
    decorate(ev.buf)
    if not vim.b[ev.buf].nb_outputs_loaded then
      vim.b[ev.buf].nb_outputs_loaded = true
      with_kernel(function() pcall(vim.cmd, "MoltenImportOutput") end)
    end
  end,
})
vim.api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
  pattern = "*.ipynb",
  callback = function(ev) decorate(ev.buf) end,
})
