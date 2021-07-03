local api = vim.api
local lsp = vim.lsp
local timer = nil
local triggers_by_buf = {}
local M = {}
local snippet = 2

local request = function(method, payload, handler)
  return lsp.buf_request(0, method, payload, handler)
end

local client_settings = {}
local completion_ctx
completion_ctx = {
  expand_snippet = false,
  isIncomplete = false,
  suppress_completeDone = false,
  col = nil,
  cursor = nil,

  pending_requests = {},
  cancel_pending = function()
    for _, cancel in pairs(completion_ctx.pending_requests) do
      cancel()
    end
    completion_ctx.pending_requests = {}
  end,
  reset = function()
    -- Cursor is not resetted here, it needs to survive a `CompleteDone` event
    completion_ctx.expand_snippet = false
    completion_ctx.isIncomplete = false
    completion_ctx.suppress_completeDone = false
    completion_ctx.col = nil
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
  if items[1] and items[1].sortText then
    table.sort(items, function(a, b) return (a.sortText or a.label) < (b.sortText or b.label) end)
  end
  local matches = {}
  for _, item in pairs(items) do
    local info = get_documentation(item)
    local kind = lsp.protocol.CompletionItemKind[item.kind] or ''
    local word
    if kind == 'Snippet' then
      word = item.label
    elseif item.insertTextFormat == snippet then
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
  return matches
end




local function reset_timer()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

function M.find_start(line, cursor_pos)
  local line_to_cursor = line:sub(1, cursor_pos)
  local idx = 0
  while true do
    local i = string.find(line_to_cursor, '[^a-zA-Z0-9_:]', idx + 1)
    if i == nil then
      break
    else
      idx = i
    end
  end
  return idx + 1
end


function M.trigger_completion()
  reset_timer()
  completion_ctx.cancel_pending()
  local cursor_pos = api.nvim_win_get_cursor(0)[2]
  local line = api.nvim_get_current_line()
  local col = completion_ctx.col or M.find_start(line, cursor_pos)
  completion_ctx.col = col
  local prefix = line:sub(col, cursor_pos)
  local params = lsp.util.make_position_params()
  local _, cancel_req = request('textDocument/completion', params, function(err, _, result, client_id)
    completion_ctx.pending_requests = {}
    assert(not err, vim.inspect(err))
    if not result then
      print('No completion result')
      return
    end
    completion_ctx.isIncomplete = result.isIncomplete
    local mode = api.nvim_get_mode()['mode']
    if mode == 'i' or mode == 'ic' then
      local opts = client_settings[client_id] or {}
      local matches = M.text_document_completion_list_to_complete_items(
        result,
        prefix,
        opts.server_side_fuzzy_completion
      )
      vim.fn.complete(col, matches)
    end
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
      -- → suppress it to avoid reseting the completion_ctx
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
      completion_ctx.col = nil
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


function M.apply_snippet(item, suffix)
  if item.textEdit then
    vim.fn['vsnip#anonymous'](item.textEdit.newText .. suffix)
  elseif item.insertText then
    vim.fn['vsnip#anonymous'](item.insertText .. suffix)
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
  local expand_snippet = item.insertTextFormat == snippet and completion_ctx.expand_snippet
  local suffix = nil
  if expand_snippet then
    -- Remove the already inserted word
    local start_char = completion_ctx.col and (completion_ctx.col - 1) or (col - #completed_item.word)
    local line = api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, true)[1]
    suffix = line:sub(col + 1)
    api.nvim_buf_set_text(bufnr, lnum, start_char, lnum, #line, {''})
  end
  completion_ctx.reset()
  if item.additionalTextEdits then
    apply_text_edits(bufnr, lnum, item.additionalTextEdits)
    if expand_snippet then
      M.apply_snippet(item, suffix)
    end
  elseif resolveEdits and type(item) == "table" then
    local _, cancel_req = request('completionItem/resolve', item, function(err, _, result)
      completion_ctx.pending_requests = {}
      assert(not err, vim.inspect(err))
      apply_text_edits(bufnr, lnum, result.additionalTextEdits)
      if expand_snippet then
        M.apply_snippet(item, suffix)
      end
    end)
    table.insert(completion_ctx.pending_requests, cancel_req)
  elseif expand_snippet then
    M.apply_snippet(item, suffix)
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
    table.insert(triggers, { signature_triggers, lsp.buf.signature_help })
  end
  local completionProvider = client.server_capabilities.completionProvider or {}
  local completion_triggers = completionProvider.triggerCharacters
  if completion_triggers and #completion_triggers > 0 then
    table.insert(triggers, { completion_triggers, M.trigger_completion })
  end
end

return M
