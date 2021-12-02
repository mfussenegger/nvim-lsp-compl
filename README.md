# nvim-lsp-compl

A fast and asynchronous auto-completion plugin for Neovim >= 0.5.1, focused on LSP.


## Motivation

Why *another* one?

I wrote the initial code for this within my dotfiles long before plugins like [nvim-compe][1] popped up and tuned it over time to accommodate my workflow.

There have been some voices looking for something smaller than [nvim-compe][1], so I decided to extract the code from my dotfiles and make it re-usable for others.


## Features

- Automatically triggers completion on trigger characters advocated by the language server
- Automatically triggers signature help on characters advocated by the language server
- Apply additional text edits (Used to resolve imports and so on)
- Supports lazy resolving of additional text edits if the language server has the capability
- Optionally supports server side fuzzy matching
- Optionally supports LSP snippet expansion if [LuaSnip][luasnip] or [vsnip][vsnip] is installed or a custom snippet-applier is registered

If you need anything else, you better use [nvim-compe][1].


### Opinionated behaviors:

- Snippets are only expanded via explicit opt-in
- The `word` in the completion candidates is tuned to *exclude* parenthesis and arguments, unless you use the snippet expansion.


## Non-Goals

- Feature parity with [nvim-compe][1]


## Installation

- Install Neovim >= 0.5.1
- Install nvim-lsp-compl like any other plugin
  - If using [vim-plug][2]: `Plug 'mfussenegger/nvim-lsp-compl'`
  - If using [packer.nvim][3]: `use 'mfussenegger/nvim-lsp-compl'`


## Configuration

You need to call the `attach` method when the language server clients attaches to a buffer.

If you're using [lspconfig][4] you could do this like this:


```lua
lua require'lspconfig'.pyls.setup{on_attach=require'lsp_compl'.attach}
```

If you want to utilize server side fuzzy completion, you would call it like this:

```lua
lua require'lspconfig'.pyls.setup{
  on_attach = function(client, bufnr)
    require'lsp_compl'.attach(client, bufnr, { server_side_fuzzy_completion = true })
  end,
}
```

To expand snippets you need to explicitly accept a completion candidate:

```vimL
inoremap <expr> <CR> (luaeval("require'lsp_compl'.accept_pum()") ? "\<c-y>" : "\<CR>")
```

Currently snippet expansion tries [LuaSnip][luasnip] if available and otherwise falls back to use [vim-vsnip][vsnip], but you can override the `expand_snippet` function to use a different snippet engine:


```lua
require('lsp_compl').expand_snippet = vim.fn['vsnip#anonymous']
```

Or

```lua
require('lsp_compl').expand_snippet = require('luasnip').lsp_expand
```


The function takes a single argument - the snippet - and is supposed to expand it.


## FAQ

### Can I disable the automatic signature popup?

Yes, if you set the `signature_help_trigger_characters` to an empty table:


```lua
on_attach = function(client, bufnr)
  client.resolved_capabilities.signature_help_trigger_characters = {}
  require'lsp_compl'.attach(client, bufnr)
end
```


### Can I customize the trigger characters for completion?

Yes, if you override the `triggerCharacters`:


```lua
on_attach = function(client, bufnr)
  client.server_capabilities.completionProvider.triggerCharacters = {'a', 'e', 'i', 'o', 'u'}
  require'lsp_compl'.attach(client, bufnr)
end
```


### Can I trigger the completion manually?

Yes, call `require'lsp_compl'.trigger_completion()` while in insert mode.
But this won't be much different from using the `vim.lsp.omnifunc` via `i_CTRL-X_CTRL-O`.


### Can I re-trigger completion when I hit backspace or `<C-w>` while completion is active?

Yes, you have three options:

1. Manually trigger the completion (see previous question)
2. Enable `trigger_on_delete`:

```lua
  -- ...
  on_attach = function(client, bufnr)
    require'lsp_compl'.attach(client, bufnr, { trigger_on_delete = true })
  end
  -- ...
```

3. Define a key mapping that always re-triggers it:

```vimL
inoremap <expr> <BS> (pumvisible() ? "\<BS><cmd> :lua require'lsp_compl'.trigger_completion()<CR>" : "\<BS>")
```


[1]: https://github.com/hrsh7th/nvim-compe
[2]: https://github.com/junegunn/vim-plug
[3]: https://github.com/wbthomason/packer.nvim
[4]: https://github.com/neovim/nvim-lspconfig
[vsnip]: https://github.com/hrsh7th/vim-vsnip
[luasnip]: https://github.com/L3MON4D3/LuaSnip
