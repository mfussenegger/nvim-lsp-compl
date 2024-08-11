# nvim-lsp-compl

A fast and asynchronous auto-completion plugin for Neovim (latest stable and nightly), focused on LSP.

For Neovim 0.5.1 support, checkout `ad95138d56b7c84fb02e7c7078e8f5e61fda4596`.

## Status

nvim-lsp-compl won't see further development and will be archived once neovim
0.11 is released because it will include a `vim.lsp.completion` module which is
to a large part based on nvim-lsp-compl.

## Motivation

Why *another* one?

I wrote the initial code for this within my dotfiles long before plugins like [nvim-compe][1] or [nvim-cmp][nvim-cmp] popped up and tuned it over time to accommodate my workflow.

There have been some voices looking for something smaller than the alternatives, so I decided to extract the code from my dotfiles and make it re-usable for others.


## Features

- Automatically triggers completion on trigger characters advocated by the language server
- Automatically triggers signature help on characters advocated by the language server
- Apply additional text edits (Used to resolve imports and so on)
- Supports lazy resolving of additional text edits if the language server has the capability
- Optionally supports server side fuzzy matching
- Optionally supports LSP snippet expansion if `vim.snippet` is available,
  [LuaSnip][luasnip] or [vsnip][vsnip] is installed or a custom snippet-applier
  is registered

If you need anything else, you better use one of the others.


If you want additional completion sources you'd need to implement a language
server. A full blown language server would have the advantage that other
editors can benefit too, but if you'd like to use Neovim functionality, you
could create a [in-process Lua language
server](https://zignar.net/2022/10/26/testing-neovim-lsp-plugins/#a-in-process-lsp-server).



### Opinionated behaviors:

- Snippets are only expanded via explicit opt-in
- The `word` in the completion candidates is tuned to *exclude* parenthesis and arguments, unless you use the snippet expansion.


## Non-Goals

- Feature parity with [nvim-compe][1]


## Installation

- Install Neovim (latest stable or nightly)
- Install nvim-lsp-compl like any other plugin
  - `git clone https://github.com/mfussenegger/nvim-lsp-compl.git ~/.config/nvim/pack/plugins/start/nvim-lsp-compl`
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

To expand snippets you need to extend the client capabilities. In the `config`
for `vim.lsp.start` (See `:help lsp-quickstart`):

```lua
local config = {
    capabilities = vim.tbl_deep_extend(
        'force',
        vim.lsp.protocol.make_client_capabilities(),
        require('lsp_compl').capabilities()
    ),
}
```


And explicitly accept a completion candidate:

```lua
vim.keymap.set('i', '<CR>', function()
  return require('lsp_compl').accept_pum() and '<c-y>' or '<CR>'
end, { expr = true })
```

Currently snippet expansion order:

- [LuaSnip][luasnip] if loaded
- `vim.snippet`
- [LuaSnip][luasnip] again, this time trying to load it.
- [vim-vsnip][vsnip]

You can override the `expand_snippet` function to use a different snippet engine:

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

Yes, if you set the `triggerCharacters` of the server to an empty table:


```lua
on_attach = function(client, bufnr)
  if client.server_capabilities.signatureHelpProvider then
    client.server_capabilities.signatureHelpProvider.triggerCharacters = {}
  end
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
[nvim-cmp]: https://github.com/hrsh7th/nvim-cmp
