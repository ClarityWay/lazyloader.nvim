# lazyloader.nvim

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)[![Neovim](https://img.shields.io/badge/Neovim-0.9%2B-blueviolet)](https://neovim.io)[![Doc](https://img.shields.io/badge/Doc-%3Ah%20lazyloader.txt-red)](doc/lazyloader.txt)

A Lua module loader for Neovim that provides both eager and lazy loading capabilities.

## Features ✨

- **Just-in-Time Loading**: Proxy tables delay module loading until first access
- **Type-Safe Configuration**: Built-in validation for all configuration options
- **Smart Path Detection**: Auto-resolves base paths from Neovim's runtimepath
- **Cache Control**:
  - Manual purge/reload capabilities
  - Automatic garbage collection
  - Instance-specific cache management
- **Multi-Instance**: Create isolated loader instances with different configurations
- **Proxy Mechanism**: Read-only proxy tables for lazy access
- **Chainable API**: Fluent interface for configuration

## Installation ⚡

### Requirements

- Neovim 0.9.0+

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "ClarityWay/lazyloader.nvim",
  opts = {
    lazy = true,
    detect_base = true,
    prefix = "",
  },
}
```

### Using [Packer.nvim](https://github.com/wbthomason/packer.nvim)

```lua
use {
  "ClarityWay/lazyloader.nvim",
  config = function()
    require("lazyloader").setup({
      lazy = true,
      detect_base = true,
      prefix = "",
    })
  end
}
```

## Quick Start 🚀

```lua
-- Basic lazy loading
local lazy = require("lazyloader").lazy
local heavy_module = lazy("my.plugin.heavy_module")
heavy_module.run()  -- First access triggers load

-- Eager loading
require("lazyloader").load("my.plugin.essential_module")

-- Type-safe configuration
require("lazyloader").setup({
  prefix = "plugins.",
  on_load = function(modname)
    print("Loading:", modname)
  end
})
```

## Configuration ⚙️

### Global Options

| Option        | Type       | Default | Validators              | Description           |
| ------------- | ---------- | ------- | ----------------------- | --------------------- |
| `lazy`        | `boolean`  | `true`  | Must be boolean         | Enable lazy-loading   |
| `detect_base` | `boolean`  | `true`  | Must be boolean         | Auto-detect base path |
| `prefix`      | `string`   | `""`    | Must be string          | Module name prefix    |
| `base_dir`    | `string`   | `nil`   | Valid filesystem path   | Custom base directory |
| `on_load`     | `function` | `nil`   | Must be function or nil | Pre-load callback     |
| `on_loaded`   | `function` | `nil`   | Must be function or nil | Post-load callback    |

### Configuration Validators

All configuration options undergo strict type validation:

```lua
-- Example validation failures
require("lazyloader").setup({
  prefix = 123,  -- Ignore this option because prefix must be string
  on_load = "not_a_function"  -- Ignore this option because on_load must be function
})
```

### Per-Call Overrides

```lua
-- Override config for specific module
local special = lazy("my.module", {
  prefix = "special.",
  detect_base = false
})
```

### Modification attempts throw errors

```lua
local proxy = lazy("my.module")
proxy.new_field = 42  -- Throws error: "Cannot modify read-only proxy"
```

## Advanced Usage 🔧

### Chainable Configuration

```lua
local loader = require("lazyloader").new()
  :lazy(true)                -- Enable lazy-loading
  :prefix("ui.components.")  -- Set module prefix
  :detect_base(false)        -- Disable auto-detection
  :on_load(function(m) print("[Loader] Initializing:", m) end)
  :on_loaded(function(m) print("[Loader] Ready:", m) end)
```

### Custom Loader Instances

```lua
local db_loader = require("lazyloader").new({
  prefix = "database.",
  lazy = false  -- Eager-load critical modules
})

db_loader:load("db.postgres")  -- Immediate loading
```

### Cache Management

```lua
-- Batch reset by pattern
db_loader:reset(nil, { prefix = "db." }) 

-- Reload module with specified config
db_loader:reload("my.module", { lazy = false })

-- Instance-specific purge
db_loader:reset("db.postgres")
```

### Multi-Instance Management 🧩

**Use Case**: Create isolated loading contexts for different subsystems

```lua
-- UI loader with component tracking
local ui_loader = require("lazyloader").new()
  :prefix("ui.components.")
  :on_load(function(m) print("[UI] Loading:", m) end)

-- Database loader with eager loading
local db_loader = require("lazyloader").new({
  prefix = "db.connectors.",
  lazy = false,  -- Load critical modules immediately
  base_dir = vim.fn.stdpath("data").."/database"
})

-- Hot-reload core modules
db_loader:reload("db.core")

-- Using Pre-configured Instances
local default_loader = require("lazyloader").lazy
local core_utils = default_loader("utils.core")
```

## API Reference 📚

### Function Invocation

The LazyLoader instance supports direct function call syntax through the `__call` metamethod:

```lua
local loader = require("lazyloader").new()

-- Basic usage (respects instance's config)
local module = loader("some.module")

-- With config override
local module = loader("some.module", { base_dir = ".." })
```

The call behavior depends on the loader's configuration:

- When `lazy = true` (default): Creates a lazy-loading proxy
- When `lazy = false` : Immediately loads the module

### Core Methods

#### `setup(opts?)`

Configure global defaults for all loader instances.

**Parameters:**

- `opts` (table|nil) - Configuration options:
  - `lazy` (boolean) - Default lazy loading (default: true)
  - `detect_base` (boolean) - Auto-detect base path (default: true)
  - `prefix` (string) - Module name prefix (default: "")
  - `base_dir` (string) - Base directory for resolution (default: caller dir)
  - `on_load` (function) - Callback before module loading
  - `on_loaded` (function) - Callback after module loaded

**Example:**

```lua
require("lazyloader").setup({
  lazy = false,
  detect_base = false
})
```

#### `new(opts?)`

Create a new loader instance with custom configuration.

**Parameters:** Same as `setup()`

**Returns:** New LazyLoader instance

**Example:**

```lua
local loader = require("lazyloader").new({ lazy = true })
```

#### `load(modname, opts?)`

Eager load a module immediately.

**Parameters:**

- `modname` (string) - Module name to load
- `opts` (table|nil) - Optional config override

**Returns:** Loaded module

**Example:**

```lua
local module = require("lazyloader").load("some.module")
```

#### `lazy(modname, opts?)`

Create lazy-loaded proxy for a module.

**Parameters:** Same as `load()`

**Returns:** Proxy table that will load on first access

**Example:**

```lua
local lazy_module = require("lazyloader").lazy("some.module")
```

### Instance Methods

#### `reset(modname?, opts?)`

Reset cached module(s).

**Parameters:**

- `modname` (string|nil) - Module name (nil for all modules)
- `opts` (table|nil) - Config for cache matching

**Example:**

```lua
loader:reset("some.module")  -- Reset single module
loader:reset(nil, { lazy = true })  -- Reset all lazy modules
```

#### `reload(modname?, opts?)`

Reload cached module(s).

**Parameters:** Same as `reset()`

**Example:**

```lua
loader:reload("some.module")  -- Force reload
```

### Chaining Methods

Configuration methods that return the instance for chaining:

```lua
loader:lazy(true)          -- Enable lazy loading
  :detect_base(false)      -- Disable auto-detection
  :prefix("plugins.")      -- Set module prefix
  :base_dir("/my/path")    -- Set base directory
  :on_load(function(modname) print("Loading:", modname) end)
```

## Contributing 🤝

1. Fork the repository
2. Create feature branch (`git checkout -b feat/amazing-feature`)
3. Commit changes following [Conventional Commits](https://www.conventionalcommits.org)
4. Push to branch (`git push origin feat/amazing-feature`)
5. Open Pull Request
