local M = {}

local _mappings = {}
local api = vim.api

local util = require("dapui.util")
local config = require("dapui.config")
M.namespace = api.nvim_create_namespace("dapui")

---@class RenderState
---@field lines table
---@field matches table
---@field mappings table
---@field prompt table
---@field valid boolean
local RenderState = {}

---@return RenderState
function RenderState:new()
  local mappings = {}
  for _, action in pairs(config.actions) do
    mappings[action] = {}
  end
  local render_state = {
    lines = {},
    matches = {},
    mappings = mappings,
    prompt = nil,
    valid = true,
  }
  setmetatable(render_state, self)
  self.__index = self
  return render_state
end

-- Used by components waiting on state update to render.
-- This is to avoid flickering updates as information is updated.
function RenderState:invalidate()
  self.valid = false
end

---Add a new line to state
---@param line string
function RenderState:add_line(line)
  self.lines[#self.lines + 1] = line or ""
end

--- Remove the last line from state
function RenderState:remove_line()
  self.lines[#self.lines] = nil
end

function RenderState:reset()
  self.lines = {}
  self.matches = {}
  self.mappings = { open = {}, expand = {}, remove = {}, edit = {} }
end

---Add a new highlight match to pass to matchaddpos
---@param group string Highlight group
---@param line number Line to add match for
---@param start_col number First column to start match
---@param length number Length of match
function RenderState:add_match(group, line, start_col, length)
  local pos = { line }
  if start_col ~= nil then
    pos[#pos + 1] = start_col
  end
  if length ~= nil then
    pos[#pos + 1] = length
  end
  self.matches[#self.matches + 1] = { group, pos }
end

---Add a mapping for a specific line
---@param action string Name of mapping action to use key for
---@param callback function Callback for when mapping is used
---@param opts table Optional extra arguments
-- Extra arguments currently accepts:
--   `line` Line to map to, defaults to last in state
function RenderState:add_mapping(action, callback, opts)
  opts = opts or {}
  local line = opts["line"] or self:length()
  self.mappings[action][line] = self.mappings[action][line] or {}
  self.mappings[action][line][#self.mappings[action][line] + 1] = callback
end

function RenderState:set_prompt(text, callback, opts)
  opts = opts or {}
  self.prompt = { text = text, callback = callback, fill = opts.fill, enter = opts.enter or false }
end

---Get the number of lines in state
function RenderState:length()
  return #self.lines
end

---Get the length of the longest line in state
function RenderState:width()
  local width = 0
  for _, line in pairs(self.lines) do
    width = width < #line and #line or width
  end
  return width
end

---Apply a render state to a buffer
---@param state RenderState
---@param buffer number
function M.render_buffer(state, buffer)
  local success, _ = pcall(api.nvim_buf_set_option, buffer, "modifiable", true)
  if not success then
    return false
  end
  if state:length() == 0 then
    return
  end
  if buffer < 0 then
    return false
  end
  local win = vim.fn.bufwinnr(buffer)
  if win == -1 then
    return false
  end

  _mappings[buffer] = state.mappings
  for action, _ in pairs(state.mappings) do
    util.apply_mapping(
      config.mappings()[action],
      "<cmd>lua require('dapui.render.state')._mapping('" .. action .. "')<CR>",
      buffer
    )
  end

  local lines = state.lines
  local matches = state.matches
  vim.fn["clearmatches"](win)
  api.nvim_buf_clear_namespace(buffer, M.namespace, 0, -1)
  api.nvim_buf_set_lines(buffer, 0, #lines, false, lines)
  local last_line = vim.fn.getbufinfo(buffer)[1].linecount
  if last_line > #lines then
    api.nvim_buf_set_lines(buffer, #lines, last_line, false, {})
  end
  for _, match in pairs(matches) do
    local pos = match[2]
    api.nvim_buf_set_extmark(
      buffer,
      M.namespace,
      pos[1] - 1,
      (pos[2] or 1) - 1,
      { end_col = pos[3] and (pos[2] + pos[3] - 1), hl_group = match[1] }
    )
  end
  if state.prompt then
    api.nvim_buf_set_option(buffer, "buftype", "prompt")
    vim.fn.prompt_setprompt(buffer, state.prompt.text)
    vim.fn.prompt_setcallback(buffer, function(value)
      vim.cmd("stopinsert")
      state.prompt.callback(value)
    end)
    if state.prompt.fill then
      vim.cmd("normal i" .. state.prompt.fill)
      api.nvim_input("A")
    end
    api.nvim_buf_set_option(buffer, "modified", false)
    api.nvim_buf_set_keymap(buffer, "i", "<BS>", "<ESC>xa", { noremap = true })
    vim.cmd("augroup DAPUIPromptSetUnmodified" .. buffer)
    vim.cmd(
      "autocmd ExitPre <buffer="
        .. buffer
        .. "> call nvim_buf_set_option("
        .. buffer
        .. ", 'modified', v:false)"
    )
    vim.cmd("augroup END")
  else
    api.nvim_buf_set_option(buffer, "modifiable", false)
    api.nvim_buf_set_option(buffer, "buftype", "nofile")
  end
  return true
end

--- @return RenderState
function M.new()
  return RenderState:new()
end

function M._mapping(action)
  local buffer = api.nvim_get_current_buf()
  local line = vim.fn.line(".")
  local callbacks = _mappings[buffer][action][line]
  if not callbacks then
    vim.notify("No " .. action .. " action for current line", "INFO")
    return
  end
  for _, callback in pairs(callbacks) do
    callback()
  end
end

return M
