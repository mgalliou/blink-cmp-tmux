# blink-cmp-tmux

Port of the [andersevenrud/cmp-tmux](https://github.com/andersevenrud/cmp-tmux)
completion source for the [blink.cmp] [Neovim](https://github.com/neovim/neovim)
plugin.

## Features

- Integrates with [tmux] to provide completion suggestions based on the content
  of [tmux] panes.
- Supports capturing content from all panes or only the current pane.
- Allows capturing the history of panes for more comprehensive suggestions.
- Never holds up typing: panes are read in the background, one after the
  other, with a deadline and a cap on what is read; a completion is answered
  from the words kept.
- Configurable trigger characters to activate completions.

## Requirements

- [tmux]
- [blink.cmp]

## Installation & Configuration

Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "saghen/blink.cmp",
  dependencies = {
      "mgalliou/blink-cmp-tmux",
  },
  opts = {
    sources = {
      default = {
        --- your other sources
        "tmux",
      },
      providers = {
        tmux = {
          module = "blink-cmp-tmux",
          name = "tmux",
          -- default options
          opts = {
            -- `panes` option supports these values:
            -- * `window`  - completions from current tmux window panes only
            -- * `session` - completions from current tmux session panes only
            -- * `all`     - completions from all tmux panes
            panes = "window",
            capture_history = false,
            -- only suggest completions from `tmux` if the `trigger_chars` are
            -- used
            triggered_only = false,
            trigger_chars = { "." },
            -- seconds between two reads of the panes
            min_update_period = 5,
            -- seconds a word stays once its pane no longer shows it
            item_lifetime = 60,
            -- milliseconds a tmux command may take
            timeout = 2000,
            -- bytes read of one pane at most
            max_bytes = 1024 * 1024,
          },
        },
      }
    }
  }
}
```

## Contributing

Contributions are welcome! Please open an issue or submit a pull request if you
have any suggestions, bug reports, or feature requests.

## Credits

- [andersevenrud](https://github.com/andersevenrud): for the original completion
  source
- [moyiz/blink-emoji.nvim](https://github.com/moyiz/blink-emoji.nvim) and
  [MahanRahmati/blink-nerdfont.nvim](https://github.com/MahanRahmati/blink-nerdfont.nvim)
  for some code inspiration

[tmux]: https://github.com/tmux/tmux
[blink.cmp]: https://github.com/Saghen/blink.cmp
