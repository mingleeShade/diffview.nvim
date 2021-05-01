local utils = require'diffview.utils'
local git = require'diffview.git'
local file_entry = require'diffview.file-entry'
local RevType = require'diffview.rev'.RevType
local Diff = require'diffview.diff'.Diff
local EditToken = require'diffview.diff'.EditToken
local FilePanel = require'diffview.file-panel'.FilePanel
local a = vim.api
local M = {}

---@class View
---@field tabpage integer
---@field git_root string
---@field path_args string[]
---@field left Rev
---@field right Rev
---@field file_panel FilePanel
---@field left_winid integer
---@field right_winid integer
---@field files FileEntry[]
---@field file_idx integer
---@field nulled boolean
---@field ready boolean
local View = {}
View.__index = View

---View constructor
---@return View
function View:new(opt)
  local this = {
    git_root = opt.git_root,
    path_args = opt.path_args,
    left = opt.left,
    right = opt.right,
    files = git.diff_file_list(opt.git_root, opt.left, opt.right, opt.path_args),
    file_idx = 1,
    nulled = false,
    ready = false
  }
  this.file_panel = FilePanel:new(
    this.git_root,
    this.files,
    this.path_args,
    git.rev_to_pretty_string(this.left, this.right)
  )
  setmetatable(this, self)
  return this
end

function View:open()
  vim.cmd("tab split")
  self.tabpage = a.nvim_get_current_tabpage()
  self:init_layout()
  local file = self:cur_file()
  if file then
    self:set_file(file)
  else
    self:file_safeguard()
  end
  self.ready = true
end

function View:close()
  for _, file in ipairs(self.files) do
    file:destroy()
  end

  if self.tabpage and a.nvim_tabpage_is_valid(self.tabpage) then
    local ok = true
    if a.nvim_get_current_tabpage() ~= self.tabpage then
      ok = pcall(a.nvim_set_current_tabpage, self.tabpage)
    end
    if ok then vim.cmd("tabclose") end
  end
end

function View:init_layout()
  self.left_winid = a.nvim_get_current_win()
  vim.cmd("belowright vsp")
  self.right_winid = a.nvim_get_current_win()
  self.file_panel:open()
end

function View:cur_file()
  if #self.files > 0 then
    return self.files[utils.clamp(self.file_idx, 1, #self.files)]
  end
  return nil
end

function View:next_file()
  self:ensure_layout()
  if self:file_safeguard() then return end

  if #self.files > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then cur:detach_buffers() end
    self.file_idx = (self.file_idx) % #self.files + 1
    vim.cmd("diffoff!")
    self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.file_panel:highlight_file(self:cur_file())
    self.nulled = false
  end
end

function View:prev_file()
  self:ensure_layout()
  if self:file_safeguard() then return end

  if #self.files > 1 or self.nulled then
    local cur = self:cur_file()
    if cur then cur:detach_buffers() end
    self.file_idx = (self.file_idx - 2) % #self.files + 1
    vim.cmd("diffoff!")
    self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
    self.file_panel:highlight_file(self:cur_file())
    self.nulled = false
  end
end

function View:set_file(file, focus)
  self:ensure_layout()
  if self:file_safeguard() or not file then return end

  for i, f in ipairs(self.files) do
    if f == file then
      local cur = self:cur_file()
      if cur then cur:detach_buffers() end
      self.file_idx = i
      vim.cmd("diffoff!")
      self.files[self.file_idx]:load_buffers(self.git_root, self.left_winid, self.right_winid)
      self.file_panel:highlight_file(self:cur_file())
      self.nulled = false

      if focus then
        a.nvim_set_current_win(self.right_winid)
      end
    end
  end
end

---Update the file list, including stats and status for all files.
function View:update_files()
  -- If left is tracking HEAD and right is LOCAL: Update HEAD rev.
  if self.left.head and self.right.type == RevType.LOCAL then
    local new_head = git.head_rev(self.git_root)
    if new_head and self.left.commit ~= new_head.commit then
      self.left = new_head
    end
  end

  local new_files = git.diff_file_list(self.git_root, self.left, self.right, self.path_args)
  local diff = Diff:new(self.files, new_files, function (aa, bb)
    return aa.path == bb.path
  end)
  local script = diff:create_edit_script()
  local cur_file = self:cur_file()

  local ai = 1
  local bi = 1
  for _, opr in ipairs(script) do
    if opr == EditToken.NOOP then
      -- Update status and stats
      self.files[ai].status = new_files[bi].status
      self.files[ai].stats = new_files[bi].stats
      ai = ai + 1
      bi = bi + 1
    elseif opr == EditToken.DELETE then
      if cur_file == self.files[ai] then self:prev_file() end
      self.files[ai]:destroy()
      table.remove(self.files, ai)
    elseif opr == EditToken.INSERT then
      table.insert(self.files, ai, new_files[bi])
      ai = ai + 1
      bi = bi + 1
    elseif opr == EditToken.REPLACE then
      if cur_file == self.files[ai] then self:prev_file() end
      self.files[ai]:destroy()
      table.remove(self.files, ai)
      table.insert(self.files, ai, new_files[bi])
      ai = ai + 1
      bi = bi + 1
    end
  end

  self.file_panel:render()
  self.file_panel:redraw()
  self.file_idx = utils.clamp(self.file_idx, 1, #self.files)
  self:set_file(self:cur_file())

  self.update_needed = false
end

---Checks the state of the view layout.
---@return table
function View:validate_layout()
  local state = {
    tabpage = a.nvim_tabpage_is_valid(self.tabpage),
    left_win = a.nvim_win_is_valid(self.left_winid),
    right_win = a.nvim_win_is_valid(self.right_winid)
  }
  state.valid = state.tabpage and state.left_win and state.right_win
  return state
end

---Recover the layout after the user has messed it up.
---@param state table
function View:recover_layout(state)
  self.ready = false

  if not state.tabpage then
    vim.cmd("tab split")
    self.tabpage = a.nvim_get_current_tabpage()
    self.file_panel:close()
    self:init_layout()
    self.ready = true
    return
  end

  a.nvim_set_current_tabpage(self.tabpage)
  self.file_panel:close()

  if not state.left_win and not state.right_win then
    self:init_layout()

  elseif not state.left_win then
    a.nvim_set_current_win(self.right_winid)
    vim.cmd("aboveleft vsp")
    self.left_winid = a.nvim_get_current_win()
    self.file_panel:open()
    self:set_file(self:cur_file())

  elseif not state.right_win then
    a.nvim_set_current_win(self.left_winid)
    vim.cmd("belowright vsp")
    self.right_winid = a.nvim_get_current_win()
    self.file_panel:open()
    self:set_file(self:cur_file())
  end

  self.ready = true
end

---Ensure both left and right windows exist in the view's tabpage.
function View:ensure_layout()
  local state = self:validate_layout()
  if not state.valid then
    self:recover_layout(state)
  end
end

---Ensures there are files to load, and loads the null buffer otherwise.
---@return boolean
function View:file_safeguard()
  if #self.files == 0 then
    local cur = self:cur_file()
    if cur then cur:detach_buffers() end
    file_entry.load_null_buffer(self.left_winid)
    file_entry.load_null_buffer(self.right_winid)
    self.nulled = true
    return true
  end
  return false
end

function View:on_enter()
  if self.ready then
    self:update_files()
  end

  local file = self:cur_file()
  if file then
    file:attach_buffers()
  end
end

function View:on_leave()
  local file = self:cur_file()
  if file then
    file:detach_buffers()
  end
end

function View:on_bufwritepost()
  if git.has_local(self.left, self.right) then
    self.update_needed = true
    if a.nvim_get_current_tabpage() == self.tabpage then
      self:update_files()
    end
  end
end

function View:on_buf_win_enter()
  if self.ready then
    local winid = a.nvim_get_current_win()
    if not (
        winid == self.file_panel.winid
        or winid == self.left_winid
        or winid == self.right_winid) then
      vim.cmd("set nodiff nocursorbind noscrollbind")
    end
  end
end

M.View = View

return M