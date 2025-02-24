local config = require("dapui.config")
local Variables = require("dapui.components.variables")
local util = require("dapui.util")
local loop = require("dapui.render.loop")

local partial = util.partial

---@class Watches
---@field expressions table
---@field expanded table
---@field var_components table
---@field state UIState
---@field mode "new"|"edit"
---@field edit_index integer
---@field rendered_step integer | nil
---@field rendered_exprs table[]
local Watches = {}

function Watches:new(state)
  local watches = {
    expressions = {},
    var_components = {},
    expanded = {},
    state = state,
    mode = "new",
    edit_index = nil,
    rendered_exprs = {},
  }
  setmetatable(watches, self)
  self.__index = self
  return watches
end

function Watches:add_watch(value)
  if value == "" then
    loop.run()
    return
  end
  self.expressions[#self.expressions + 1] = value
  self.var_components[#self.var_components + 1] = Variables(self.state)
  self.state:add_watch(value)
end

function Watches:edit_expr(new_value)
  self.mode = "new"
  local index = self.edit_index
  self.edit_index = nil
  local old = self.expressions[index]
  if new_value == "" then
    loop.run()
    return
  end
  self.expressions[index] = new_value
  self.state:remove_watch(old)
  self.state:add_watch(new_value)
end

function Watches:remove_expr(expr_i)
  local expression = util.pop(self.expressions, expr_i)
  self.var_components[expr_i] = nil
  self.state:remove_watch(expression)
  loop.run()
end

function Watches:toggle_expression(expr_i)
  local expanded = self.expanded[expr_i]
  if expanded then
    self.expanded[expr_i] = nil
  else
    self.expanded[expr_i] = true
  end
  loop.run()
end

function Watches:render(render_state)
  if self.mode == "new" then
    render_state:set_prompt("> ", partial(self.add_watch, self))
  else
    local old_val = self.expressions[self.edit_index]
    render_state:set_prompt("> ", partial(self.edit_expr, self), { fill = old_val })
  end
  if vim.tbl_count(self.expressions) == 0 then
    local message = "No Expressions"
    render_state:add_line(message)
    render_state:add_match("DapUIWatchesEmpty", render_state:length(), 1, #message)
    render_state:add_line()
    return
  end
  local watches = self.state:watches()
  for i, expr in pairs(self.expressions) do
    local line_no = render_state:length() + 1

    local watch = watches[expr]
    if not vim.tbl_isempty(watch or {}) then
      local var_ref = watch.evaluated and watch.evaluated.variablesReference
      local prefix = config.icons()[self.expanded[i] and "expanded" or "collapsed"]

      local new_line = ""
      render_state:add_match(
        watch.error and "DapUIWatchesError" or "DapUIWatchesValue",
        line_no,
        1,
        #prefix
      )

      new_line = new_line .. prefix .. " " .. expr

      local val_start = 0
      if watch.error then
        self.expanded[i] = false
        new_line = new_line .. ": "
        val_start = #new_line
        new_line = new_line .. watch.error
      elseif watch.evaluated then
        local evaluated = watch.evaluated
        if #(evaluated.type or "") > 0 then
          new_line = new_line .. " "
          render_state:add_match("DapUIType", line_no, #new_line + 1, #evaluated.type)
          new_line = new_line .. evaluated.type
        end
        new_line = new_line .. " = "
        val_start = #new_line
        new_line = new_line .. evaluated.result
      end
      local var_group
      if
        not self.rendered_exprs[i]
        or not watch.evaluated
        or self.rendered_exprs[i].result == watch.evaluated.result
      then
        var_group = "DapUIValue"
      else
        var_group = "DapUIModifiedValue"
      end
      for j, line in pairs(vim.split(new_line, "\n")) do
        if j > 1 then
          line = string.rep(" ", val_start - 2) .. line
        end
        render_state:add_match(
          var_group,
          line_no - 1 + j,
          val_start + (j > 1 and -1 or 1),
          #line - val_start + (j > 1 and 2 or 0)
        )
        render_state:add_line(line)
        render_state:add_mapping(config.actions.REMOVE, partial(self.remove_expr, self, i))
        render_state:add_mapping(config.actions.EDIT, function()
          self.edit_index = i
          self.mode = "edit"
          loop.run()
        end)
        if not watch.error then
          render_state:add_mapping(config.actions.EXPAND, partial(self.toggle_expression, self, i))
          render_state:add_mapping(config.actions.REPL, partial(util.send_to_repl, expr))
        end
      end

      if self.var_components[i] and self.expanded[i] then
        local child_vars = self.state:variables(var_ref)
        if not child_vars then
          render_state:invalidate()
        else
          self.var_components[i]:render(render_state, var_ref, child_vars, config.windows().indent)
        end
      end
      if self.rendered_step ~= self.state:step_number() then
        self.rendered_exprs[i] = watch.evaluated
      end
    end
  end
  if self.rendered_step ~= self.state:step_number() then
    self.rendered_step = self.state:step_number()
  end
  render_state:add_line()
end

---@param state UIState
---@return Watches
return function(state)
  return Watches:new(state)
end
