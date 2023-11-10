local api = vim.api
local lsp = vim.lsp
local rtt_ms = 50
local ns_to_ms = 0.000001
local M = {}
local SNIPPET = 2

---@type nil|uv.uv_timer_t
local completion_timer = nil

---@type nil|uv.uv_timer_t
local signature_timer = nil


if vim.fn.has('nvim-0.7') ~= 1 then
  vim.notify(
    'LSP-compl requires nvim-0.7 or higher. '
    .. 'Stick to `ad95138d56b7c84fb02e7c7078e8f5e61fda4596` if you use an earlier version of neovim',
    vim.log.levels.ERROR
  )
  return
end


---@class lsp_compl.handle
---@field clients table<integer, lsp_compl.client>
---@field has_fuzzy boolean
---@field signature_triggers table<string, lsp_compl.client[]>
---@field completion_triggers table<string, lsp_compl.client[]>
---@field leading_debounce number
---@field subsequent_debounce? number

---@type table<integer, lsp_compl.handle>
local buf_handles = {}

---@class lsp_compl.client
---@field lspclient lsp.Client
---@field opts lsp_compl.client_opts

--- @class lsp_compl.client_opts
--- @field server_side_fuzzy_completion? boolean
--- @field trigger_on_delete? boolean
--- @field leading_debounce? number
--- @field subsequent_debounce? number


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

---@class lsp.ItemDefaults
---@field editRange nil|lsp.Range|{insert: lsp.Range, replace: lsp.Range}
---@field insertTextFormat nil|number
---@field insertTextMode nil|lsp.InsertTextMode
---@field data any


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
    textEdit.newText = textEdit.newText or item.textEditText or item.insertText
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


---@param client_id integer
---@param item lsp.CompletionItem
---@param fuzzy boolean
function M._convert_item(client_id, item, fuzzy, offset)
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
      word = vim.fn.matchstr(item.insertText, "\\k*")
    else
      word = item.label
    end
  elseif item.textEdit then
    word = item.textEdit.newText
    word = word:match("^(%S*)") or word
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
    user_data = {
      client_id = client_id,
      item = item
    }
  }
end


---@param client_id integer
---@param items lsp.CompletionItem[]
---@param fuzzy boolean
---@param offset integer
---@param prefix string
function M.text_document_completion_list_to_complete_items(client_id, items, fuzzy, offset, prefix)
  if #items == 0 then
    return {}
  end
  local matches = {}
  for _, item in ipairs(items) do
    if not fuzzy and item.filterText and prefix ~= "" then
      if next(vim.fn.matchfuzzy({item.filterText}, prefix)) then
        local candidate = M._convert_item(client_id, item, fuzzy, offset)
        table.insert(matches, candidate)
      end
    else
      table.insert(matches, M._convert_item(client_id, item, fuzzy, offset))
    end
  end
  table.sort(matches, function(a, b)
    local txta = a.user_data.item.sortText or a.user_data.item.label
    local txtb = b.user_data.item.sortText or b.user_data.item.label
    return txta < txtb
  end)
  return matches
end


---@param timer? uv.uv_timer_t
local function reset_timer(timer)
  if timer then
    timer:stop()
    timer:close()
  end
  return nil
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
  local min_start = nil
  local min_end = nil

  for _, item in pairs(items) do
    if item.textEdit and item.textEdit.range.start.line == lnum - 1 then
      local range = item.textEdit.range
      if min_start and min_start ~= range.start.character then
        return nil
      end

      if range.start.character > range['end'].character then
        return nil
      end
      min_start = range.start.character
      min_end = range["end"].character
    end
  end
  if min_start then
    if encoding == 'utf-8' then
      return min_start, min_end
    else
      if min_end then
        min_end = vim.str_byteindex(line, min_end, encoding == 'utf-16')
      end
      return vim.str_byteindex(line, min_start, encoding == 'utf-16'), min_end
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


---@param clients table<integer, lsp_compl.client>
---@param bufnr integer
---@param win integer
---@param callback fun(responses: table)
local function request(clients, bufnr, win, callback)
  local results = {}
  local request_ids = {}
  local remaining_results = vim.tbl_count(clients)
  for client_id, client in pairs(clients) do
    local lspclient = client.lspclient
    local params = lsp.util.make_position_params(win, lspclient.offset_encoding)

    ---@diagnostic disable-next-line: invisible
    local ok, request_id = lspclient.request('textDocument/completion', params, function(err, result)
      results[client_id] = { err = err, result = result }
      remaining_results = remaining_results - 1
      if remaining_results == 0 then
        callback(results)
      end
    end, bufnr)
    if ok then
      request_ids[client_id] = request_id
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


---@param client_id integer
---@param encoding string
---@param result lsp.CompletionItem[]|lsp.CompletionList
---@param lnum integer
---@param line string
---@param word_boundary integer byte_offset 0-index
---@param startbyte? integer byte_offset 0-index
---@param fuzzy boolean
---@return table[], integer?
function M._convert_items(client_id,
                          encoding,
                          result,
                          lnum,
                          line,
                          word_boundary,
                          startbyte,
                          fuzzy)
  local items = get_completion_items(result)
  local current_startbyte, end_boundary = adjust_start_col(lnum, line, items, encoding)
  if startbyte == nil then
    startbyte = current_startbyte
  elseif current_startbyte ~= nil and current_startbyte ~= startbyte then
    startbyte = word_boundary
  end
  local offset = startbyte and (word_boundary - startbyte) or 0
  local prefix = line:sub((startbyte or word_boundary) + 1, end_boundary)
  local matches = M.text_document_completion_list_to_complete_items(
    client_id,
    items,
    fuzzy,
    math.max(0, offset),
    prefix
  )
  return matches, startbyte
end


function M.trigger_completion()
  completion_timer = reset_timer(completion_timer)
  completion_ctx.cancel_pending()
  local win = api.nvim_get_current_win()
  local bufnr = api.nvim_get_current_buf()
  local lnum, cursor_pos = unpack(api.nvim_win_get_cursor(win))
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, cursor_pos)
  local word_boundary = vim.fn.match(line_to_cursor, '\\k*$')
  local start = vim.loop.hrtime()
  completion_ctx.last_request = start
  local clients = (buf_handles[bufnr] or {}).clients or {}

  local cancel_req = request(clients, bufnr, win, function(responses)
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
      if response.err then
        vim.notify_once(response.err.message, vim.log.levels.WARN)
      end
      local result = response.result
      if result then
        completion_ctx.isIncomplete = completion_ctx.isIncomplete or result.isIncomplete
        local client = vim.lsp.get_client_by_id(client_id)
        local encoding = client and client.offset_encoding or 'utf-16'
        local opts = (clients[client_id] or {}).opts
        local matches
        matches, startbyte = M._convert_items(
          client_id,
          encoding,
          result,
          lnum,
          line,
          word_boundary,
          startbyte,
          opts.server_side_fuzzy_completion or false
        )
        vim.list_extend(all_matches, matches)
      end
    end
    local startcol = (startbyte or word_boundary) + 1
    vim.fn.complete(startcol, all_matches)
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


local function signature_help()
  signature_timer = reset_timer(signature_timer)
  local params = lsp.util.make_position_params()
  lsp.buf_request(0, 'textDocument/signatureHelp', params, function(err, result, ctx, conf)
    conf = conf and vim.deepcopy(conf) or {}
    conf.focusable = false
    vim.lsp.handlers['textDocument/signatureHelp'](err, result, ctx, conf)
  end)
end


---@param handle lsp_compl.handle
local function insert_char_pre(handle)
  local pumvisible = tonumber(vim.fn.pumvisible()) == 1
  if pumvisible then
    if completion_ctx.isIncomplete or handle.has_fuzzy then
      completion_timer = reset_timer(completion_timer)
      -- Calling vim.fn.complete while pumvisible will trigger `CompleteDone` for the active completion window;
      -- → suppress it to avoid resetting the completion_ctx
      completion_ctx.suppress_completeDone = true

      local debounce_ms = next_debounce(handle.subsequent_debounce)
      if debounce_ms == 0 then
        vim.schedule(M.trigger_completion)
      else
        completion_timer = assert(vim.loop.new_timer(), "Must be able to create timer")
        completion_timer:start(debounce_ms, 0, vim.schedule_wrap(M.trigger_completion))
      end
    end
    return
  end
  local char = api.nvim_get_vvar('char')
  if not completion_timer and handle.completion_triggers[char] ~= nil then
    completion_timer = assert(vim.loop.new_timer(), "Must be able to create timer")
    completion_timer:start(handle.leading_debounce, 0, function()
      completion_timer = reset_timer(completion_timer)
      vim.schedule(M.trigger_completion)
    end)
  end
  if not signature_timer and handle.signature_triggers[char] ~= nil then
    signature_timer = assert(vim.loop.new_timer(), "Must be able to create timer")
    signature_timer:start(handle.leading_debounce, 0, function()
      signature_timer = reset_timer(signature_timer)
      vim.schedule(signature_help)
    end)
  end
end


local function text_changed_p()
  completion_ctx.cursor = api.nvim_win_get_cursor(0)
end


local function text_changed_i()
  local cursor = completion_ctx.cursor
  if not cursor or completion_timer then
    return
  end
  local current_cursor = api.nvim_win_get_cursor(0)
  if current_cursor[1] == cursor[1] and current_cursor[2] <= cursor[2] then
    completion_timer = assert(vim.loop.new_timer(), "Must be able to create timer")
    completion_timer:start(150, 0, vim.schedule_wrap(M.trigger_completion))
  elseif current_cursor[1] ~= cursor[1] then
    completion_ctx.cursor = nil
  end
end


local function insert_leave()
  signature_timer = reset_timer(signature_timer)
  completion_timer = reset_timer(completion_timer)
  completion_ctx.cursor = nil
  completion_ctx.reset()
end


--- Expands a snippet.
--- Uses one of:
---  - vim.snippet.expand
---  - luasnip
---  - vsnip
---
--- Override to use a different snippet engine.
---
---@param snippet string
function M.expand_snippet(snippet)
  -- Check luasnip/vsnip first to avoid behavior change due to vim.snippet addition.
  if package.loaded["luasnip"] then
    require("luasnip").lsp_expand(snippet)
    return
  end
  if vim.fn.exists("*vsnip#anonymous") == 1 then
    vim.fn['vsnip#anonymous'](snippet)
  end
  if vim.snippet then
    vim.snippet.expand(snippet)
    return
  end
  local ok, luasnip = pcall(require, 'luasnip')
  if ok then
    luasnip(snippet)
  end
  vim.notify_once(
    "No snippet provider available. Install luasnip/vsnip, update neovim for vim.snippet or override expand_snippet",
    vim.log.levels.WARN
  )
end


local function apply_snippet(item, suffix)
  if item.textEdit then
    M.expand_snippet(item.textEdit.newText .. suffix)
  elseif item.insertText then
    M.expand_snippet(item.insertText .. suffix)
  end
end


local function complete_done()
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
  local user_data = completed_item.user_data
  local item = user_data.item  --[[@as lsp.CompletionItem]]
  local client_id = user_data.client_id
  if not item or not client_id then
    completion_ctx.reset()
    return
  end
  local bufnr = api.nvim_get_current_buf()
  local expand_snippet = (
    item.insertTextFormat == SNIPPET
    and completion_ctx.expand_snippet
    and (item.textEdit ~= nil or item.insertText ~= nil)
  )
  completion_ctx.reset()
  local client = vim.lsp.get_client_by_id(client_id)
  if not client then
    return
  end
  local offset_encoding = client.offset_encoding or 'utf-16'
  local resolve_edits = (client.server_capabilities.completionProvider or {}).resolveProvider

  ---@return string? suffix
  local function clear_word()
    if not expand_snippet then
      return nil
    end
    -- Remove the already inserted word
    local start_char = col - #completed_item.word
    local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, true)[1]
    api.nvim_buf_set_text(bufnr, lnum, start_char, lnum, #line, {''})
    local suffix = line:sub(col + 1)
    return suffix
  end

  ---@param suffix string?
  local function apply_snippet_and_command(suffix)
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
  if item.additionalTextEdits and next(item.additionalTextEdits) then
    local suffix = clear_word()
    lsp.util.apply_text_edits(item.additionalTextEdits, bufnr, offset_encoding)
    apply_snippet_and_command(suffix)
  elseif resolve_edits and type(item) == "table" then
    local changedtick = vim.b[bufnr].changedtick
    client.request('completionItem/resolve', item, function(err, result)
      if changedtick ~= vim.b[bufnr].changedtick then
        return
      end
      local suffix = clear_word()
      if err then
        vim.notify(err.message, vim.log.levels.WARN)
      elseif result and result.additionalTextEdits then
        lsp.util.apply_text_edits(result.additionalTextEdits, bufnr, offset_encoding)
        if result.command then
          item.command = result.command
        end
      end
      apply_snippet_and_command(suffix)
    end, bufnr)
  else
    local suffix = clear_word()
    apply_snippet_and_command(suffix)
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
  local handle = buf_handles[bufnr]
  if not handle then
    return
  end
  handle.clients[client_id] = nil
  if not next(handle.clients) then
    buf_handles[bufnr] = nil
    local group = string.format('lsp_compl_%d', bufnr)
    api.nvim_del_augroup_by_name(group)
  else
    ---@param c lsp_compl.client
    local function is_other_client(c)
      return c.lspclient.id ~= client_id
    end
    for k, clients in pairs(handle.signature_triggers) do
      handle.signature_triggers[k] = vim.tbl_filter(is_other_client, clients)
    end
    for k, clients in pairs(handle.completion_triggers) do
      handle.completion_triggers[k] = vim.tbl_filter(is_other_client, clients)
    end
  end
end


---@param client lsp.Client
local function init_commands(client)
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
end


---@param client lsp.Client
---@param bufnr integer
---@param opts? lsp_compl.client_opts
function M.attach(client, bufnr, opts)
  ---@type lsp_compl.client_opts
  opts = vim.tbl_extend('keep', opts or {}, {
    server_side_fuzzy_completion = false,
    trigger_on_delete = false,
  })

  local handle = buf_handles[bufnr]
  if not handle then
    handle = {
      clients = {},
      signature_triggers = {},
      completion_triggers = {},
      has_fuzzy = false,
      leading_debounce = opts.leading_debounce or 25,
      subsequent_debounce = opts.subsequent_debounce
    }
    buf_handles[bufnr] = handle
    api.nvim_buf_attach(bufnr, false, {
      on_detach = function(_, b)
        buf_handles[b] = nil
      end,
      on_reload = function(_, b)
        M.attach(client, b, opts)
      end
    })
    local group = string.format('lsp_compl_%d', bufnr)
    api.nvim_create_augroup(group, { clear = true })
    local create_autocmd = api.nvim_create_autocmd
    create_autocmd('InsertCharPre', {
      group = group,
      buffer = bufnr,
      callback = function() insert_char_pre(handle) end,
    })
    if opts.trigger_on_delete then
      create_autocmd('TextChangedP', { group = group, buffer = bufnr, callback = text_changed_p })
      create_autocmd('TextChangedI', { group = group, buffer = bufnr, callback = text_changed_i })
    end
    create_autocmd('InsertLeave', { group = group, buffer = bufnr, callback = insert_leave, })
    create_autocmd('CompleteDone', { group = group, buffer = bufnr, callback = complete_done })
  end

  handle.has_fuzzy = handle.has_fuzzy or (opts.server_side_fuzzy_completion or false)
  handle.leading_debounce = math.max(handle.leading_debounce, 0)
  if handle.subsequent_debounce and opts.subsequent_debounce then
    handle.subsequent_debounce = math.max(handle.subsequent_debounce, opts.subsequent_debounce)
  end

  local compl_client = handle.clients[client.id]
  if not compl_client then
    init_commands(client)
    compl_client = {
      lspclient = client,
      opts = opts
    }
    handle.clients[client.id] = compl_client
  end

  ---@param map table<string, lsp_compl.client>
  ---@param triggers? string[]
  local function add_client(map, triggers)
    for _, char in ipairs(triggers or {}) do
      local clients = map[char]
      local exists = false
      if clients then
        for _, c in pairs(clients) do
          if c.lspclient.id == client.id then
            exists = true
            break
          end
        end
      else
        clients = {}
        map[char] = clients
      end
      if not exists then
        table.insert(clients, compl_client)
      end
    end
  end

  add_client(handle.signature_triggers, vim.tbl_get(
    client.server_capabilities,
    'signatureHelpProvider',
    'triggerCharacters'
  ))
  add_client(handle.completion_triggers, vim.tbl_get(
    client.server_capabilities,
    "completionProvider",
    "triggerCharacters"
  ))
end


--- Returns the LSP capabilities this plugin adds.
--- Must be merged into capabilities created with `vim.lsp.protocol.make_client_capabilities()`
---
---   local capabilities = vim.tbl_deep_extend(
---     'force',
---     vim.lsp.protocol.make_client_capabilities(),
---     require('lsp_compl').capabilities()
---   )
---@return table
function M.capabilities()
  local has_snippet_support = (
    package.loaded["luasnip"] ~= nil
    or vim.fn.exists('*vsnip#anonymous') == 1
    or vim.snippet ~= nil
  )
  return {
    textDocument = {
      completion = {
        completionItem = {
          snippetSupport = has_snippet_support,
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
