if os.getenv("LOCAL_LUA_DEBUGGER_VSCODE") == "1" then
  require("lldebugger").start()
end
local api = vim.api
local compl = require('lsp_compl')

local messages = {}
---@diagnostic disable-next-line: deprecated
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients

local function new_server(completion_result)
  local function server(dispatchers)
    local closing = false
    local srv = {}

    function srv.request(method, params, callback)
      table.insert(messages, {
        method = method,
        params = params,
      })
      if method == 'initialize' then
        callback(nil, {
          capabilities = {
            completionProvider = {
              triggerCharacters = {'.'}
            }
          }
        })
      elseif method == 'textDocument/completion' then
        callback(nil, completion_result)
      elseif method == 'shutdown' then
        callback(nil, nil)
      end
    end

    function srv.notify(method, _)
      if method == 'exit' then
        dispatchers.on_exit(0, 15)
      end
    end

    function srv.is_closing()
      return closing
    end

    function srv.terminate()
      closing = true
    end

    return srv
  end
  return server
end


local function wait(condition, msg)
  vim.wait(100, condition)
  local result = condition()
  assert.are_not.same(false, result, msg)
  assert.are_not.same(nil, result, msg)
end


describe('lsp_compl', function()
  local buf = api.nvim_create_buf(false, true)
  local win = api.nvim_get_current_win()
  local capture = {}

  ---@diagnostic disable-next-line: duplicate-set-field
  vim.fn.complete = function(col, matches)
    capture.col = col
    capture.matches = matches
  end
  ---@diagnostic disable-next-line: duplicate-set-field
  api.nvim_get_mode = function()
    return {
      mode = 'i'
    }
  end
  api.nvim_win_set_buf(win, buf)
  api.nvim_create_autocmd("LspDetach", {
    callback = function(args)
      compl.detach(args.data.client_id, args.buf)
    end,
  })

  before_each(function()
    capture = {}
    messages = {}
  end)

  after_each(function()
    vim.lsp.stop_client(get_clients())
    wait(function() return vim.tbl_count(get_clients()) == 0 end, 'clients must stop')
    assert.are.same({}, get_clients())
  end)

  it('fetches completions and shows them using complete on trigger_completion', function()
    local completion_result = {
      isIncomplete = false,
      items = {
        {
          label = 'hello',
        }
      }
    }
    local server = new_server(completion_result)
    vim.lsp.start({ name = 'fake-server', cmd = server, on_attach = compl.attach })
    api.nvim_buf_set_lines(buf, 0, -1, true, {'a'})
    api.nvim_win_set_cursor(win, { 1, 1 })
    compl.trigger_completion()
    wait(function() return capture.col ~= nil end)
    assert.are.same(2, #messages)
    local expected_matches = {
      {
        abbr = 'hello',
        dup = 1,
        empty = 1,
        equal = 0,
        icase = 1,
        info = '',
        kind = '',
        menu = '',
        user_data = {
          client_id = 1,
          item = {
            label = 'hello',
          }
        },
        word = 'hello'
      }
    }
    assert.are.same(expected_matches, capture.matches)
  end)

  it('merges results from multiple clients', function()
    local server1 = new_server({
      isIncomplete = false,
      items = {
        {
          label = 'hello',
        }
      }
    })
    vim.lsp.start({ name = 'server1', cmd = server1, on_attach = compl.attach })
    local server2 = new_server({
      isIncomplete = false,
      items = {
        {
          label = 'hallo',
        }
      }
    })
    vim.lsp.start({ name = 'server2', cmd = server2, on_attach = compl.attach })
    api.nvim_buf_set_lines(buf, 0, -1, true, {'a'})
    api.nvim_win_set_cursor(win, { 1, 1 })
    compl.trigger_completion()
    wait(function() return capture.col ~= nil end, "must have a capture: " .. vim.inspect(capture))
    assert.are.same(2, #capture.matches)
    assert.are.same('hello', capture.matches[1].word)
    assert.are.same('hallo', capture.matches[2].word)
  end)

  it('uses defaults from itemDefaults', function()
    local server = new_server({
      isIncomplete = false,
      itemDefaults = {
        editRange = {
          start = { line = 1, character = 1 },
          ['end'] = { line = 1, character = 4 },
        },
        insertTextFormat = 2,
        data = 'foobar',
      },
      items = {
        {
          label = 'hello',
          data = 'item-property-has-priority',
          textEditText ='hello',
        }
      }
    })
    vim.lsp.start({ name = 'server', cmd = server, on_attach = compl.attach })
    api.nvim_buf_set_lines(buf, 0, -1, true, {'a'})
    api.nvim_win_set_cursor(win, { 1, 1 })
    compl.trigger_completion()
    local candidate = capture.matches[1]
    assert.are.same('hello', candidate.word)
    assert.are.same(2, candidate.user_data.item.insertTextFormat)
    assert.are.same('item-property-has-priority', candidate.user_data.item.data)
    assert.are.same({ line = 1, character = 1}, candidate.user_data.item.textEdit.range.start)
  end)

  it("uses insertText as textEdit.newText if there are editRange defaults but no textEditText", function()
    local server = new_server({
      isIncomplete = false,
      itemDefaults = {
        editRange = {
          start = { line = 1, character = 1 },
          ['end'] = { line = 1, character = 4 },
        },
        insertTextFormat = 2,
        data = 'foobar',
      },
      items = {
        {
          insertText = "the-insertText",
          label = 'hello',
          data = 'item-property-has-priority',
        }
      }
    })
    vim.lsp.start({ name = 'server', cmd = server, on_attach = compl.attach })
    api.nvim_buf_set_lines(buf, 0, -1, true, {'a'})
    api.nvim_win_set_cursor(win, { 1, 1 })
    compl.trigger_completion()
    local candidate = capture.matches[1]
    local item = candidate.user_data.item
    assert.are.same("the-insertText", item.textEdit.newText)
  end)

  it('executes commands', function()
    local items = {
      {
        label = 'hello',
        command = {
          arguments = { "1", "0" },
          command = "dummy",
          title = ""
        }
      }
    }
    local server = new_server({ isIncomplete = false, items = items })
    local client_id = vim.lsp.start({ name = 'dummy', cmd = server, on_attach = compl.attach })
    assert(client_id)
    local client = assert(vim.lsp.get_client_by_id(client_id))
    local called = false
    client.commands.dummy = function()
      called = true
    end
    compl.trigger_completion()
    vim.v.completed_item = {
      user_data = {
        item = items[1],
        client_id = client_id
      }
    }
    api.nvim_exec_autocmds('CompleteDone', {
      buffer = api.nvim_get_current_buf()
    })
    local candidate = capture.matches[1]
    assert.are.same('hello', candidate.word)
    assert.are.same(true, called)
  end)
end)

describe('item conversion', function()
  it('uses insertText as word if available and shorter than label', function()
    local lsp_item = {
      insertText = "query_definition",
      label = "query_definition(pattern)",
    }
    local item = compl._convert_item(1, lsp_item, false, 0)
    assert.are.same('query_definition', item.word)
  end)
  it('uses label as word if insertText available but longer than label and format is snippet', function()
    local lsp_item = {
      insertTextFormat = 2,
      insertText = "testSuites ${1:Env}",
      label = "testSuites",
    }
    local item = compl._convert_item(1, lsp_item, false, 0)
    assert.are.same('testSuites', item.word)
  end)

  it("uses label if textEdit.newText doesn't start with label", function()
    local lsp_item = {
      insertTextFormat = 2,
      textEdit = {
        newText = "table.insert(f, $0)",
      },
      label = "insert",
    }
    local item = compl._convert_item(1, lsp_item, false, 0)
    assert.are.same('insert', item.word)
  end)

  it("Uses text if label matches prefix with offset applied", function()
    -- vscode-json-languageserver includes quotes in the newText, but not in the label
    local lsp_item = {
      insertTextFormat = 2,
      textEdit = {
        newText = '"arrow_spacing"',
      },
      label = "arrow_spacing"
    }
    local item = compl._convert_item(1, lsp_item, false, 1)
    assert.are.same('"arrow_spacing"', item.word, 1)
  end)

  it("Strips trailing newline and tab from textEdit.newText", function()
    local lsp_item = {
      textEdit = {
        newText = 'ansible.builtin.cpm_serial_port_info:\n\t',
      },
      label = "ansible.builtin.cpm_serial_port_info"
    }
    local item = compl._convert_item(1, lsp_item, false, 1)
    assert.are.same("ansible.builtin.cpm_serial_port_info:", item.word)
  end)

  it("Does not fuzzy filter items with filterText if prefix is empty", function()
    local items = {
      {
        label = "dummy",
        filterText = "dummy",
      }
    }
    local result = compl.text_document_completion_list_to_complete_items(1, items, false, 0, "")
    assert.are.same(1, #result)
  end)
  it("fuzzy filter with word boundary before cursor", function()
    local line = "  ansible."
    local lnum = 1
    local word_boundary = 2
    local item1 = {
      kind = 7,
      label = "ansible.builtin.meta",
      sortText = "2_ansible.builtin.meta",
      filterText = "meta ansible.builtin.meta builtin ansible",
      textEdit = {
        newText = "ansible.builtin.meta:\n",
        range = {
          start = {
            line = 1,
            character = 2
          },
          ["end"] = {
            line = 1,
            character = 10
          }
        }
      }
    }
    local item2 = {
      kind = 18,
      label = "arista.eos.system",
      sortText = "3_arista.eos.system",
      filterText = "system arista.eos.system eos arista",
      textEdit = {
        newText = "arista.eos.system:\n",
        range = {
          start = {
            line = 0,
            character = 2
          },
          ["end"] = {
            line = 0,
            character = 10
          }
        }
      }
    }
    local response = { item1, item2 }
    local result = compl._convert_items(
      1,
      "utf-16",
      response,
      lnum,
      line,
      word_boundary,
      nil,
      false
    )
    assert.are.same(1, #result)
    assert.are.same("ansible.builtin.meta:", result[1].word)
  end)

  it("Doesn't filter items with suffix", function()
    local line = "        <version></version>"
    local lnum = 1
    local word_boundary = 17
    local response = {
      isIncomplete = false,
      itemDefaults = {
        insertTextFormat = 2,
        editRange = {
          start = {
            line = 0,
            character = 17,
          },
          ["end"] = {
            line = 0,
            character = 17
          }
        }
      },
      items =  {
        {
          filterText = "3.1.2",
          insertTextFormat = 1,
          kind = 10,
          label = "3.1.2",
          sortText = "000000.3.1.2",
          textEditText = "3.1.2"
        }
      }
    }
    local result = compl._convert_items(
      1,
      "utf-16",
      response,
      lnum,
      line,
      word_boundary,
      nil,
      false
    )
    assert.are.same(1, #result)
  end)
end)
