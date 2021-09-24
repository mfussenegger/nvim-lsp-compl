local api = vim.api
local lsp = vim.lsp
local timer = nil
local triggers_by_buf = {}
local M = {}
local SNIPPET = 2


local function mk_handler(fn)
  return function(...)
    local config_or_client_id = select(4, ...)
    local is_new = type(config_or_client_id) ~= 'number'
    if is_new then
      fn(...)
    else
      local err = select(1, ...)
      local method = select(2, ...)
      local result = select(3, ...)
      local client_id = select(4, ...)
      local bufnr = select(5, ...)
      local config = select(6, ...)
      fn(err, result, { method = method, client_id = client_id, bufnr = bufnr }, config)
    end
  end
end


local function request(bufnr, method, params, handler)
  return lsp.buf_request(bufnr, method, params, mk_handler(handler))
end


local client_settings = {}
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
    completion_ctx.cancel_pending()
  end
}


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


function M.text_document_completion_list_to_complete_items(result, prefix, fuzzy)
  local items = lsp.util.extract_completion_items(result)
  if #items == 0 then
    return {}
  end
  local matches = {}
  for _, item in pairs(items) do
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
        word = item.insertText or item.textEdit.newText
      elseif item.insertText then
        if #item.label < #item.insertText then
          word = item.label
        else
          word = item.insertText
        end
      else
        word = item.label
      end
    else
      word = (item.textEdit and item.textEdit.newText) or item.insertText or item.label
    end
    if fuzzy or vim.startswith(word, prefix) then
      table.insert(matches, {
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
      })
    end
  end
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
      if min_start_char and min_start_char ~= item.textEdit.range.start.character then
        return nil
      end
      min_start_char = item.textEdit.range.start.character
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


function M.trigger_completion()
  reset_timer()
  completion_ctx.cancel_pending()
  local lnum, cursor_pos = unpack(api.nvim_win_get_cursor(0))
  local line = api.nvim_get_current_line()
  local line_to_cursor = line:sub(1, cursor_pos)
  local col = vim.fn.match(line_to_cursor, '\\k*$') + 1
  local params = lsp.util.make_position_params()
  local _, cancel_req = request(0, 'textDocument/completion', params, function(err, result, ctx)
    local client_id = ctx.client_id
    completion_ctx.pending_requests = {}
    assert(not err, vim.inspect(err))
    if not result then
      print('No completion result')
      return
    end
    completion_ctx.isIncomplete = result.isIncomplete
    local line_changed = api.nvim_win_get_cursor(0)[1] ~= lnum
    local mode = api.nvim_get_mode()['mode']
    if line_changed or not (mode == 'i' or mode == 'ic') then
      return
    end
    local client = vim.lsp.get_client_by_id(client_id)
    local items = lsp.util.extract_completion_items(result)
    local encoding = client and client.offset_encoding or 'utf-16'
    local startbyte = adjust_start_col(lnum, line, items, encoding) or col
    local opts = client_settings[client_id] or {}
    local prefix = line:sub(startbyte, cursor_pos)
    local matches = M.text_document_completion_list_to_complete_items(
      result,
      prefix,
      opts.server_side_fuzzy_completion
    )
    vim.fn.complete(startbyte, matches)
  end)
  table.insert(completion_ctx.pending_requests, cancel_req)
end


function M._InsertCharPre(server_side_fuzzy_completion)
  if timer then
    return
  end
  local char = api.nvim_get_vvar('char')
  local pumvisible = tonumber(vim.fn.pumvisible()) == 1
  if pumvisible then
    if completion_ctx.isIncomplete or server_side_fuzzy_completion then
      -- Calling vim.fn.complete will trigger `CompleteDone` for the active completion window;
      -- → suppress it to avoid resetting the completion_ctx
      completion_ctx.suppress_completeDone = true
      timer = vim.loop.new_timer()
      timer:start(150, 0, vim.schedule_wrap(M.trigger_completion))
    end
    return
  end
  local triggers = triggers_by_buf[api.nvim_get_current_buf()] or {}
  for _, entry in pairs(triggers) do
    local chars, fn = unpack(entry)
    if vim.tbl_contains(chars, char) then
      timer = vim.loop.new_timer()
      timer:start(50, 0, function()
        reset_timer()
        vim.schedule(fn)
      end)
      return
    end
  end
end


function M._TextChangedP()
  completion_ctx.cursor = api.nvim_win_get_cursor(0)
end


function M._TextChangedI()
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


function M._InsertLeave()
  reset_timer()
  completion_ctx.cursor = nil
  completion_ctx.reset()
end


local function apply_text_edits(bufnr, lnum, text_edits)
  -- Text edit in the same line would mess with the cursor position
  local edits = vim.tbl_filter(
    function(x) return x.range.start.line ~= lnum end,
    text_edits or {}
  )
  lsp.util.apply_text_edits(edits, bufnr)
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


function M._CompleteDone(resolveEdits)
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
  local item = completed_item.user_data
  local bufnr = api.nvim_get_current_buf()
  local expand_snippet = item.insertTextFormat == SNIPPET and completion_ctx.expand_snippet
  local suffix = nil
  if expand_snippet then
    -- Remove the already inserted word
    local start_char = col - #completed_item.word
    local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, true)[1]
    suffix = line:sub(col + 1)
    api.nvim_buf_set_text(bufnr, lnum, start_char, lnum, #line, {''})
  end
  completion_ctx.reset()
  if item.additionalTextEdits then
    if expand_snippet then
      apply_snippet(item, suffix)
    end
    apply_text_edits(bufnr, lnum, item.additionalTextEdits)
  elseif resolveEdits and type(item) == "table" then
    local _, cancel_req = request(bufnr, 'completionItem/resolve', item, function(err, result)
      completion_ctx.pending_requests = {}
      assert(not err, vim.inspect(err))
      if expand_snippet then
        apply_snippet(item, suffix)
      end
      apply_text_edits(bufnr, lnum, result.additionalTextEdits)
    end)
    table.insert(completion_ctx.pending_requests, cancel_req)
  elseif expand_snippet then
    apply_snippet(item, suffix)
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
  vim.cmd(string.format('augroup lsp_compl_%d_%d', client_id, bufnr))
  vim.cmd('au!')
  vim.cmd('augroup end')
  vim.cmd(string.format('augroup! lsp_compl_%d_%d', client_id, bufnr))
  client_settings[client_id] = nil
end


local function signature_help()
  reset_timer()
  local params = lsp.util.make_position_params()
  request(0, 'textDocument/signatureHelp', params, function(...)
    local config_or_client_id = select(4, ...)
    local is_new = type(config_or_client_id) ~= 'number'
    local config_idx = is_new and 4 or 6
    local config = select(config_idx, ...) or {}
    config.focusable = false
    if is_new then
      vim.lsp.handlers['textDocument/signatureHelp'](
        select(1, ...),
        select(2, ...),
        select(3, ...),
        config
      )
    else
      vim.lsp.handlers['textDocument/signatureHelp'](
        select(1, ...),
        select(2, ...),
        select(3, ...),
        select(4, ...),
        select(5, ...),
        config
      )
    end
  end)
end


function M.attach(client, bufnr, opts)
  opts = opts or {}
  client_settings[client.id] = opts
  vim.cmd(string.format('augroup lsp_compl_%d_%d', client.id, bufnr))
  vim.cmd('au!')
  vim.cmd(string.format(
    "autocmd InsertCharPre <buffer=%d> lua require'lsp_compl'._InsertCharPre(%s)",
    bufnr,
    opts.server_side_fuzzy_completion or false
  ))
  if opts.trigger_on_delete then
    vim.cmd(string.format("autocmd TextChangedP <buffer=%d> lua require'lsp_compl'._TextChangedP()", bufnr))
    vim.cmd(string.format("autocmd TextChangedI <buffer=%d> lua require'lsp_compl'._TextChangedI()", bufnr))
  end
  vim.cmd(string.format("autocmd InsertLeave <buffer=%d> lua require'lsp_compl'._InsertLeave()", bufnr))
  vim.cmd(string.format(
    "autocmd CompleteDone <buffer=%d> lua require'lsp_compl'._CompleteDone(%s)",
    bufnr,
    (client.server_capabilities.completionProvider or {}).resolveProvider
  ))
  vim.cmd('augroup end')

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
  local signature_triggers = client.resolved_capabilities.signature_help_trigger_characters
  if signature_triggers and #signature_triggers > 0 then
    table.insert(triggers, { signature_triggers, signature_help })
  end
  local completionProvider = client.server_capabilities.completionProvider or {}
  local completion_triggers = completionProvider.triggerCharacters
  if completion_triggers and #completion_triggers > 0 then
    table.insert(triggers, { completion_triggers, M.trigger_completion })
  end
end

return M
