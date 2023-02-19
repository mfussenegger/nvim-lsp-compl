local api = vim.api
local lsp = vim.lsp
local timer = nil
local triggers_by_buf = {}
local rtt_ms = 50
local ns_to_ms = 0.000001
local M = {}
local SNIPPET = 2

if vim.fn.has('nvim-0.7') ~= 1 then
  vim.notify(
    'LSP-compl requires nvim-0.7 or higher. '
    .. 'Stick to `ad95138d56b7c84fb02e7c7078e8f5e61fda4596` if you use an earlier version of neovim',
    vim.log.levels.ERROR
  )
  return
end


--- @class lsp_compl.client_opts
--- @field server_side_fuzzy_completion boolean
--- @field leading_debounce number
--- @field subsequent_debounce number|nil
--- @field trigger_on_delete boolean

--- @class lsp_compl.client
--- @field num_attached number
--- @field opts lsp_compl.client_opts

--- @type table<number, lsp_compl.client>
local clients = {}
local completion_ctx
completion_ctx = {
  expand_snippet = false,
  isIncomplete = false,
  suppress_completeDone = false,
  cursor = nil,

  pending_requests = {},
  cancel_pending = function()
    for _, cancel in pairs(completion_ctx.pending_requests) do
      cancel()
    end
    completion_ctx.pending_requests = {}
  end,
  reset = function()
    -- Cursor is not reset here, it needs to survive a `CompleteDone` event
    completion_ctx.expand_snippet = false
    completion_ctx.isIncomplete = false
    completion_ctx.suppress_completeDone = false
    completion_ctx.last_request = nil
    completion_ctx.cancel_pending()
  end
}


---@class lsp.CompletionItemLabelDetails
---@field detail nil|string
---@field description nil|string


---@alias lsp.InsertTextMode 1|2

---@class lsp.TextEdit
---@field range lsp.Range
---@field newText string

---@class lsp.InsertReplaceEdit
---@field newText string
---@field insert lsp.Range
---@field replace lsp.Range

---@class lsp.Command
---@field title string
---@field command string
---@field arguments any|nil

---@class lsp.Position
---@field line number
---@field character number

---@class lsp.Range
---@field start lsp.Position
---@field end lsp.Position

---@class lsp.ItemDefaults
---@field editRange nil|lsp.Range|{insert: lsp.Range, replace: lsp.Range}
---@field insertTextFormat nil|number
---@field insertTextMode nil|lsp.InsertTextMode
---@field data any

---@class lsp.CompletionItem
---@field label string
---@field labelDetails nil|lsp.CompletionItemLabelDetails
---@field kind nil|number
---@field tags nil|number[]
---@field detail nil|string
---@field documentation nil|string|lsp.MarkupContent
---@field deprecated nil|boolean
---@field preselect nil|boolean
---@field sortText nil|string
---@field filterText nil|string
---@field insertText nil|string
---@field insertTextFormat nil|number
---@field insertTextMode nil|lsp.InsertTextMode
---@field textEdit nil|lsp.TextEdit|lsp.InsertReplaceEdit
---@field textEditText nil|string
---@field additionalTextEdits nil|lsp.TextEdit[]
---@field commitCharacters nil|string[]
---@field command nil|lsp.Command
---@field data nil|any


---@class lsp.CompletionList
---@field isIncomplete boolean
---@field itemDefaults lsp.ItemDefaults|nil
---@field items lsp.CompletionItem[]


---@param item lsp.CompletionItem
---@return string
local function get_documentation(item)
  local docs = item.documentation
  if type(docs) == 'string' then
    return docs
  end
  if type(docs) == 'table' and type(docs.value) == 'string' then
    return docs.value
  end
  return ''
end

---@param item lsp.CompletionItem
---@param defaults lsp.ItemDefaults|nil
local function apply_defaults(item, defaults)
  if not defaults then
    return
  end
  item.insertTextFormat = item.insertTextFormat or defaults.insertTextFormat
  item.insertTextMode = item.insertTextMode or defaults.insertTextMode
  item.data = item.data or defaults.data
  if defaults.editRange then
    local textEdit = item.textEdit or {}
    item.textEdit = textEdit
    textEdit.newText = textEdit.newText or item.textEditText
    if defaults.editRange.start then
      textEdit.range = textEdit.range or defaults.editRange
    elseif defaults.editRange.insert then
      textEdit.insert = defaults.editRange.insert
      textEdit.replace = defaults.editRange.replace
    end
  end
end


--- Extract the completion items from a `textDocument/completion` response
--- and apply defaults
---
---@param result lsp.CompletionItem[]|lsp.CompletionList
---@returns lsp.CompletionItem[]
local function get_completion_items(result)
  if result.items then
    for _, item in pairs(result.items) do
      apply_defaults(item, result.itemDefaults)
    end
    return result.items
  else
    return result
  end
end


---@param item lsp.CompletionItem
---@param fuzzy boolean
function M._convert_item(item, fuzzy, offset)
  local info = get_documentation(item)
  local kind = lsp.protocol.CompletionItemKind[item.kind] or ''
  local word
  if kind == 'Snippet' then
    word = item.label
  elseif item.insertTextFormat == SNIPPET then
    --[[
    -- eclipse.jdt.ls has
    --      insertText = "wait",
    --      label = "wait() : void"
    --      textEdit = { ... }
    --
    -- haskell-ide-engine has
    --      insertText = "testSuites ${1:Env}"
    --      label = "testSuites"
    --
    -- lua-language-server has
    --      insertText = "query_definition",
    --      label = "query_definition(pattern)",
    --]]
    if item.textEdit then
      local text = item.insertText or item.textEdit.newText

      -- Use label instead of text if text has different starting characters.
      -- label is used as abbr (=displayed), but word is used for filtering
      -- This is required for things like postfix completion.
      -- E.g. in lua:
      --
      --    local f = {}
      --    f@|
      --      ^
      --      - cursor
      --
      --    item.textEdit.newText: table.insert(f, $0)
      --    label: insert
      --
      -- Typing `i` would remove the candidate because newText starts with `t`.
      word = (fuzzy or vim.startswith(text:sub(offset + 1), item.label)) and text or item.label
    elseif item.insertText and item.insertText ~= "" then
      if #item.label < #item.insertText then
        word = item.label
      else
        word = item.insertText
      end
    else
      word = item.label
    end
  elseif item.textEdit then
    word = item.textEdit.newText
  elseif item.insertText and item.insertText ~= "" then
    word = item.insertText
  else
    word = item.label
  end
  return {
    word = word,
    abbr = item.label,
    kind = kind,
    menu = item.detail or '',
    info = info,
    icase = 1,
    dup = 1,
    empty = 1,
    equal = fuzzy and 1 or 0,
    user_data = item
  }
end


---@param result lsp.CompletionItem[]|lsp.CompletionList
---@param fuzzy boolean
---@param offset number
function M.text_document_completion_list_to_complete_items(result, fuzzy, offset)
  local items = get_completion_items(result)
  if #items == 0 then
    return {}
  end
  local convert = function(item)
    return M._convert_item(item, fuzzy, offset)
  end
  local matches = vim.tbl_map(convert, items)
  table.sort(matches, function(a, b)
    return (a.user_data.sortText or a.user_data.label) < (b.user_data.sortText or b.user_data.label)
  end)
  return matches
end


local function reset_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end


local function adjust_start_col(lnum, line, items, encoding)
  -- vim.fn.complete takes a startbyte and selecting a completion entry will
  -- replace anything between the startbyte and the current cursor position
  -- with the completion item's word
  --
  -- `col` is derived using `vim.fn.match(line_to_cursor, '\\k*$') + 1`
  -- Which works for most cases to find the word boundary, but the language
  -- server may work with a different boundary.
  --
  -- Luckily, the LSP response contains an (optional) `textEdit` with range,
  -- which indicates which boundary the language server used.
  --
  -- Concrete example, in Lua where there is currently a known mismatch:
  --
  -- require('plenary.asy|
  --         ▲       ▲   ▲
  --         │       │   │
  --         │       │   └── cursor_pos: 20
  --         │       └────── col: 17
  --         └────────────── textEdit.range.start.character: 9
  --                                 .newText = 'plenary.async'
  --
  -- Caveat:
  --  - textEdit.range can (in theory) be different *per* item.
  --  - range.start.character is (usually) a UTF-16 offset
  --
  -- Approach:
  --  - Use textEdit.range.start.character *only* if *all* items contain the same value
  --    Otherwise we'd have to normalize the `word` value.
  --
  local min_start_char = nil

  for _, item in pairs(items) do
    if item.textEdit and item.textEdit.range.start.line == lnum - 1 then
      local range = item.textEdit.range
      if min_start_char and min_start_char ~= range.start.character then
        return nil
      end

      if range.start.character > range['end'].character then
        return nil
      end
      min_start_char = range.start.character
    end
  end
  if min_start_char then
    if encoding == 'utf-8' then
      return min_start_char + 1
    else
      return vim.str_byteindex(line, min_start_char, encoding == 'utf-16') + 1
    end
  else
    return nil
  end
end


local function exp_avg(window, warmup)
  local count = 0
  local sum = 0
  local value = 0

  return function(sample)
    if count < warmup then
      count = count + 1
      sum = sum + sample
      value = sum / count
    else
      local factor = 2.0 / (window + 1)
      value = value * (1 - factor) + sample * factor
    end
    return value
  end
end

local compute_new_average = exp_avg(10, 10)


local function request(opts, callback)
  local attached_clients = {}
  for client_id, _ in pairs(clients) do
    local client = vim.lsp.get_client_by_id(client_id)
    if client and lsp.buf_is_attached(opts.bufnr, client.id) then
      table.insert(attached_clients, client)
    end
  end
  local results = {}
  local request_ids = {}
  local remaining_results = #attached_clients
  for _, client in pairs(attached_clients) do
    local params = lsp.util.make_position_params(opts.win, client.offset_encoding)
    local ok, request_id = client.request('textDocument/completion', params, function(err, result)
      results[client.id] = { err = err, result = result }
      remaining_results = remaining_results - 1
      if remaining_results == 0 then
        callback(results)
      end
    end)
    if ok then
      request_ids[client.id] = request_id
    end
  end
  return function()
    for client_id, request_id in pairs(request_ids) do
      local client = vim.lsp.get_client_by_id(client_id)
      if client then
        client.cancel_request(request_id)
      end
    end
  end
end


function M.trigger_completion()
  reset_timer()
  completion_ctx.cancel_pending()
  local win = api.nvim_get_current_win()
  local bufnr = api.nvim_get_current_buf()
  local lnum, cursor_pos = unpack(api.nvim_win_get_cursor(win))
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, cursor_pos)
  local col = vim.fn.match(line_to_cursor, '\\k*$') + 1
  local start = vim.loop.hrtime()
  completion_ctx.last_request = start

  local cancel_req = request({ bufnr = bufnr, win = win }, function(responses)
    local end_ = vim.loop.hrtime()
    rtt_ms = compute_new_average((end_ - start) * ns_to_ms)
    completion_ctx.pending_requests = {}
    completion_ctx.isIncomplete = false

    local line_changed = api.nvim_win_get_cursor(win)[1] ~= lnum
    local mode = api.nvim_get_mode()['mode']
    if line_changed or not (mode == 'i' or mode == 'ic') then
      return
    end

    local all_matches = {}
    local startbyte
    for client_id, response in pairs(responses) do
      assert(not response.err, vim.inspect(response.err))
      local result = response.result
      if result then
        completion_ctx.isIncomplete = completion_ctx.isIncomplete or result.isIncomplete
        local client = vim.lsp.get_client_by_id(client_id)
        local items = get_completion_items(result)
        local encoding = client and client.offset_encoding or 'utf-16'
        local current_startbyte = adjust_start_col(lnum, line, items, encoding)
        if startbyte == nil then
          startbyte = current_startbyte
        elseif current_startbyte ~= nil and current_startbyte ~= startbyte then
          startbyte = col
        end
        local opts = (clients[client_id] or {}).opts
        local offset = startbyte and (col - startbyte) or 0
        local matches = M.text_document_completion_list_to_complete_items(
          result,
          opts.server_side_fuzzy_completion,
          math.max(0, offset)
        )
        vim.list_extend(all_matches, matches)
      end
    end
    vim.fn.complete(startbyte or col, all_matches)
  end)
  table.insert(completion_ctx.pending_requests, cancel_req)
end


local function next_debounce(subsequent_debounce)
  local debounce_ms = subsequent_debounce or rtt_ms
  if not completion_ctx.last_request then
    return debounce_ms
  end
  local ms_since_request = (vim.loop.hrtime() - completion_ctx.last_request) * ns_to_ms
  return math.max((ms_since_request - debounce_ms) * -1, 0)
end


local function insert_char_pre(client_id)
  local opts = clients[client_id].opts
  local pumvisible = tonumber(vim.fn.pumvisible()) == 1
  if pumvisible then
    if completion_ctx.isIncomplete or opts.server_side_fuzzy_completion then
      reset_timer()
      -- Calling vim.fn.complete will trigger `CompleteDone` for the active completion window;
      -- → suppress it to avoid resetting the completion_ctx
      completion_ctx.suppress_completeDone = true

      local debounce_ms = next_debounce(opts.subsequent_debounce)
      if debounce_ms == 0 then
        vim.schedule(M.trigger_completion)
      else
        timer = vim.loop.new_timer()
        timer:start(debounce_ms, 0, vim.schedule_wrap(M.trigger_completion))
      end
    end
    return
  end

  if timer then
    return
  end
  local char = api.nvim_get_vvar('char')
  local triggers = triggers_by_buf[api.nvim_get_current_buf()] or {}
  for _, entry in pairs(triggers) do
    local chars, fn = unpack(entry)
    if vim.tbl_contains(chars, char) then
      timer = vim.loop.new_timer()
      timer:start(opts.leading_debounce, 0, function()
        reset_timer()
        vim.schedule(fn)
      end)
      return
    end
  end
end


local function text_changed_p()
  completion_ctx.cursor = api.nvim_win_get_cursor(0)
end


local function text_changed_i()
  local cursor = completion_ctx.cursor
  if not cursor or timer then
    return
  end
  local current_cursor = api.nvim_win_get_cursor(0)
  if current_cursor[1] == cursor[1] and current_cursor[2] <= cursor[2] then
    timer = vim.loop.new_timer()
    timer:start(150, 0, vim.schedule_wrap(M.trigger_completion))
  elseif current_cursor[1] ~= cursor[1] then
    completion_ctx.cursor = nil
  end
end


local function insert_leave()
  reset_timer()
  completion_ctx.cursor = nil
  completion_ctx.reset()
end


M.expand_snippet = function(snippet)
  local ok, luasnip = pcall(require, 'luasnip')
  local fn = ok and luasnip.lsp_expand or vim.fn['vsnip#anonymous']
  fn(snippet)
end


local function apply_snippet(item, suffix)
  -- TODO: move cursor back to end of new text?
  if item.textEdit then
    M.expand_snippet(item.textEdit.newText .. suffix)
  elseif item.insertText then
    M.expand_snippet(item.insertText .. suffix)
  end
end


local function complete_done(client_id)
  if completion_ctx.suppress_completeDone then
    completion_ctx.suppress_completeDone = false
    return
  end
  local completed_item = api.nvim_get_vvar('completed_item')
  if not completed_item or not completed_item.user_data then
    completion_ctx.reset()
    return
  end
  local lnum, col = unpack(api.nvim_win_get_cursor(0))
  lnum = lnum - 1
  local item = completed_item.user_data  --[[@as lsp.CompletionItem]]
  local bufnr = api.nvim_get_current_buf()
  local expand_snippet = (
    item.insertTextFormat == SNIPPET
    and completion_ctx.expand_snippet
    and (item.textEdit ~= nil or item.insertText ~= nil)
  )
  local suffix = nil
  if expand_snippet then
    -- Remove the already inserted word
    local start_char = col - #completed_item.word
    local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, true)[1]
    suffix = line:sub(col + 1)
    api.nvim_buf_set_text(bufnr, lnum, start_char, lnum, #line, {''})
  end
  completion_ctx.reset()
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return
  end
  local offset_encoding = client.offset_encoding or 'utf-16'
  local resolve_edits = (client.server_capabilities.completionProvider or {}).resolveProvider
  local apply_snippet_and_command = function()
    if expand_snippet then
      apply_snippet(item, suffix)
    end
    local command = item.command
    if command then
      local fn = client.commands[command.command] or vim.lsp.commands[command.command]
      if fn then
        local context = {
          bufnr = bufnr,
          client_id = client_id
        }
        fn(command, context)
      else
        local command_provider = client.server_capabilities.executeCommandProvider or {}
        local server_commands = command_provider.commands or {}
        if vim.tbl_contains(server_commands, command.command) then
          local params = {
            command = command.command,
            arguments = command.arguments,
          }
          client.request('workspace/executeCommand', params, function() end, bufnr)
        else
          vim.notify(
            'Command not supported on client or server: ' .. command.command,
            vim.log.levels.WARN
          )
        end
      end
    end
  end
  if item.additionalTextEdits then
    lsp.util.apply_text_edits(item.additionalTextEdits, bufnr, offset_encoding)
    apply_snippet_and_command()
  elseif resolve_edits and type(item) == "table" then
    client.request('completionItem/resolve', item, function(err, result)
      if err then
        vim.notify(err.message, vim.log.levels.WARN)
      elseif result and result.additionalTextEdits then
        lsp.util.apply_text_edits(result.additionalTextEdits, bufnr, offset_encoding)
        if result.command then
          item.command = result.command
        end
      end
      apply_snippet_and_command()
    end, bufnr)
  else
    apply_snippet_and_command()
  end
end


function M.accept_pum()
  if tonumber(vim.fn.pumvisible()) == 0 then
    return false
  else
    completion_ctx.expand_snippet = true
    return true
  end
end


function M.detach(client_id, bufnr)
  local group = string.format('lsp_compl_%d_%d', client_id, bufnr)
  api.nvim_del_augroup_by_name(group)
  local c = clients[client_id]
  c.num_attached = c.num_attached - 1
  if (c.num_attached == 0) then
    clients[client_id] = nil
  end
end


local function signature_help()
  reset_timer()
  local params = lsp.util.make_position_params()
  lsp.buf_request(0, 'textDocument/signatureHelp', params, function(err, result, ctx, config)
    local conf = config and vim.deepcopy(config) or {}
    conf.focusable = false
    vim.lsp.handlers['textDocument/signatureHelp'](err, result, ctx, conf)
  end)
end


function M.attach(client, bufnr, opts)
  local cmd_trigger_completion = 'editor.action.triggerSuggest'
  local cmd_trigger_signature = 'editor.action.triggerParameterHints'
  if not vim.lsp.commands[cmd_trigger_completion] and not client.commands[cmd_trigger_completion] then
    client.commands[cmd_trigger_completion] = function()
      local ok, result = pcall(M.trigger_completion)
      if ok then
        return vim.NIL
      else
        return vim.lsp.rpc_response_error(vim.lsp.protocol.ErrorCodes.InternalError, result)
      end
    end
  end
  if not vim.lsp.commands[cmd_trigger_signature] and not client.commands[cmd_trigger_signature] then
    client.commands[cmd_trigger_signature] = function()
      local ok, result = pcall(signature_help)
      if ok then
        return vim.NIL
      else
        return vim.lsp.rpc_response_error(vim.lsp.protocol.ErrorCodes.InternalError, result)
      end
    end
  end
  opts = vim.tbl_extend('keep', opts or {}, {
    server_side_fuzzy_completion = false,
    leading_debounce = 25,
    subsequent_debounce = nil,
    trigger_on_delete = false,
  })
  local client_settings = clients[client.id] or {
    num_attached = 0
  }
  clients[client.id] = client_settings
  client_settings.num_attached = client_settings.num_attached + 1
  client_settings.opts = opts
  local group = string.format('lsp_compl_%d_%d', client.id, bufnr)
  api.nvim_create_augroup(group, { clear = true })
  local create_autocmd = api.nvim_create_autocmd
  create_autocmd('InsertCharPre', {
    group = group,
    buffer = bufnr,
    callback = function() insert_char_pre(client.id) end,
  })
  if opts.trigger_on_delete then
    create_autocmd('TextChangedP', { group = group, buffer = bufnr, callback = text_changed_p })
    create_autocmd('TextChangedI', { group = group, buffer = bufnr, callback = text_changed_i })
  end
  create_autocmd('InsertLeave', { group = group, buffer = bufnr, callback = insert_leave, })
  create_autocmd('CompleteDone', {
    group = group,
    buffer = bufnr,
    callback = function() complete_done(client.id) end,
  })

  local triggers = triggers_by_buf[bufnr]
  if not triggers then
    triggers = {}
    triggers_by_buf[bufnr] = triggers
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(_, b)
        triggers_by_buf[b] = nil
      end
    })
  end
  local signature_triggers = vim.tbl_get(client.server_capabilities, 'signatureHelpProvider', 'triggerCharacters')
  if signature_triggers and #signature_triggers > 0 then
    table.insert(triggers, { signature_triggers, signature_help })
  end
  local completionProvider = client.server_capabilities.completionProvider or {}
  local completion_triggers = completionProvider.triggerCharacters
  if completion_triggers and #completion_triggers > 0 then
    table.insert(triggers, { completion_triggers, M.trigger_completion })
  end
end


--- Returns the LSP capabilities this plugin adds.
--- Must be merged into capabilities created with `vim.lsp.protocol.make_client_capabilities()`
---
---   local capabilities = vim.tbl_deep_extend(
---     'force',
---     vim.lsp.protocol.make_client_capabilities(),
---     require('lsp_compl').capabilities()
---   )
function M.capabilities()
  local has_snippet_support = pcall(require, 'luasnip') or vim.fn['vsnip#anonymous'] ~= nil
  return {
    textDocument = {
      completion = {
        completionItem = {
          snippetSupport = has_snippet_support,
          labelDetailsSupport = true,
          resolveSupport = {
            properties = {'edit', 'documentation', 'detail', 'additionalTextEdits'}
          },
        },
        completionList = {
          itemDefaults = {
            "editRange",
            "insertTextFormat",
            "insertTextMode",
            "data"
          },
        }
      }
    }
  }
end

return M
