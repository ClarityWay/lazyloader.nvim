---@class LazyLoader
---@field setup fun(opts?: LazyLoader.Config)
---@field new fun(opts?: LazyLoader.Config): LazyLoader
---@field reset fun(self: LazyLoader, modname?: string, opts?: LazyLoader.Config)
---@field reload fun(self: LazyLoader, modname: string, opts?: LazyLoader.Config)
---@overload fun(modname: string, opts?: LazyLoader.Config): any

---@class (exact) LazyLoader.Meta: LazyLoader
---@field __index LazyLoader
local LazyLoader = {}
LazyLoader.__index = LazyLoader

--#region Core Data Structures -------------------------------------------------

-- Weak-referenced tables for instance management
---@type table<LazyLoader, LazyLoader.Data>
local loaders = setmetatable({}, { __mode = "k" })

---@type table<LazyLoader.Proxy, LazyLoader.ProxyData>
local proxy_registry = setmetatable({}, { __mode = "k" })

--#endregion

--#region Helper Functions -----------------------------------------------------

---
---Get directory path of the caller function
---
---@return string # Normalized directory path
local function get_caller_dir()
  -- Skip 3 stack levels: `get_caller_dir()` -> `LazyLoader.new()` -> caller
  local info = debug.getinfo(3, "S")

  -- Fallback to current directory when:
  -- 1. No debug info available
  -- 2. Source isn't a file (e.g. string input)
  if not info or info.source:sub(1, 1) ~= "@" then return vim.fn.getcwd() end

  -- Normalize path handling:
  -- 1. Remove leading '@' from source path
  -- 2. Resolve symlinks and relative paths via `uv.fs_realpath `to get the absolute path
  local raw_path = info.source:sub(2)
  local realpath = vim.uv.fs_realpath(raw_path)

  -- Get caller's directory or fallback to `$PWD`
  return realpath and vim.fs.dirname(realpath) or vim.fn.getcwd()
end

--#endregion

--#region Type Definitions -----------------------------------------------------

---@alias LazyLoader.Validator fun(v: any): any Config validator type

---@class (exact) LazyLoader.Config Configuration options for LazyLoader
---@field lazy? boolean Whether to use lazy loading (default: true)
---@field detect_base? boolean Auto-detect base path from runtimepath (default: true)
---@field prefix? string Module name prefix (default: "")
---@field base_dir? string Base directory for module resolution (default: caller dir)
---@field on_load? fun(modname: string) Callback before module loading
---@field on_loaded? fun(modname: string) Callback after module loaded

---@class (exact) LazyLoader.Data Internal data structure for loader instances
---@field config LazyLoader.Config Merged configuration
---@field caller_dir? string Directory path of the caller file
---@field cache table<string, LazyLoader.ModuleCache> Module cache storage

---@class (exact) LazyLoader.ModuleCache Cache entry for individual module
---@field loaded? boolean Loading status flag
---@field modname? string Full resolved module name
---@field origin_mod? string Original requested module name
---@field module? any The loaded module object
---@field base? string Calculated base path
---@field proxy? LazyLoader.Proxy Proxy table for lazy access
---@field config? LazyLoader.Config Effective config for this module

---@class (exact) LazyLoader.ProxyData Internal data structure for proxy objects
---@field manager LazyLoader Parent loader instance
---@field modname string Original module name
---@field cache_key string Unique cache identifier
---@field loader LazyLoader.Data Associated loader data

--#endregion

--#region Configuration Validators ---------------------------------------------

---Validation functions for configuration options
---@type table<string, LazyLoader.Validator>
local validators = {
  bool = function(v)
    return not not v
  end,
  string = function(v)
    return type(v) == "string" and v or nil
  end,
  path = function(v)
    return type(v) == "string" and vim.fs.normalize(v) or nil
  end,
  func = function(v)
    return type(v) == "function" and v or nil
  end,
}

---@type LazyLoader.Config
local default_opts = {
  lazy = true,
  detect_base = true,
  prefix = "",
  base_dir = "",
  on_load = nil,
  on_loaded = nil,
}

--#endregion

--#region Chainable Configuration Methods --------------------------------------

---@class LazyLoader
---@field lazy fun(self: LazyLoader, value: boolean): LazyLoader Set lazy mode
---@field detect_base fun(self: LazyLoader, value: boolean): LazyLoader Toggle auto base detection
---@field prefix fun(self: LazyLoader, value: string): LazyLoader Set module prefix
---@field base_dir fun(self: LazyLoader, value: string): LazyLoader Set base directory
---@field on_load fun(self: LazyLoader, value: fun(modname: string)): LazyLoader Set pre-load hook
---@field on_loaded fun(self: LazyLoader, value: fun(modname: string)): LazyLoader Set post-load hook

local chain_methods = {
  lazy = { name = "lazy", validator = validators.bool },
  detect_base = { name = "detect_base", validator = validators.bool },
  prefix = { name = "prefix", validator = validators.string },
  base_dir = { name = "base_dir", validator = validators.path },
  on_load = { name = "on_load", validator = validators.func },
  on_loaded = { name = "on_loaded", validator = validators.func },
}

for method, chainable in pairs(chain_methods) do
  ---
  ---Chainable configuration method
  ---
  ---@generic T: LazyLoader
  ---@param self T
  ---@param value any New value to set
  ---@return T # self for chaining
  LazyLoader[method] = function(self, value)
    local opt = chainable.validator(value)
    if opt ~= nil then loaders[self].config[chainable.name] = opt end
    return self
  end
end

--#endregion

--#region Global Configuration -----------------------------------------------

---
---Configure global default options for all LazyLoader instances
---
---@param opts? LazyLoader.Config Optional configuration table
function LazyLoader.setup(opts)
  if not opts then return end

  for _, chainable in pairs(chain_methods) do
    local name = chainable.name
    if opts[name] then
      local opt = chainable.validator(opts[name])
      if opt ~= nil then default_opts[name] = opt end
    end
  end
end

--#endregion

--#region Constructor ----------------------------------------------------------

---
---Create new LazyLoader instance
---
---@param opts? LazyLoader.Config Initial configuration
---@return LazyLoader # New loader instance with chaining capability
function LazyLoader.new(opts)
  local config = vim.deepcopy(default_opts)

  -- Merge defaults with user options (user opts take precedence)
  if opts then
    for _, chainable in pairs(chain_methods) do
      local name = chainable.name
      if opts[name] then
        local opt = chainable.validator(opts[name])
        if opt ~= nil then config[name] = opt end
      end
    end
  end

  -- Initialize loader instance
  local loader = {}
  loaders[loader] = {
    config = config,
    caller_dir = config.detect_base and get_caller_dir() or nil,
    cache = {},
  }

  return setmetatable(loader, LazyLoader)
end

--#endregion

--#region Core Functionality ---------------------------------------------------

---
---Detect base module path from runtimepath
---
---@param caller_dir string Caller's directory path
---@param config LazyLoader.Config Loader configuration
---@return string # Resolved base path with dot notation (e.g. "plugins.core.")
local function detect_base(caller_dir, config)
  local is_absolute = config.base_dir:match("^(%a:)?/")
  local base_dir = is_absolute and config.base_dir or vim.fs.normalize(vim.fs.joinpath(caller_dir, config.base_dir))

  -- Match against Neovim's runtimepath
  local rtp_dirs = vim.api.nvim_get_runtime_file("lua", true)
  local _, root_dir = vim.iter(ipairs(rtp_dirs)):find(function(_, rtp_dir)
    return vim.startswith(base_dir, rtp_dir:gsub("\\", "/"))
  end)

  base_dir = root_dir and base_dir:sub(#root_dir + 2) or ""

  -- Convert filesystem path to Lua module notation
  local base = base_dir:gsub("/", ".")
  return base ~= "" and base .. "." or ""
end

---
---Generate unique cache key for module+config combination
---
---@param self LazyLoader Loader instance
---@param modname string Target module name
---@param opts? LazyLoader.Config Optional config override
---@return string # Unique cache identifier
local function get_cache_key(self, modname, opts)
  local config = opts and vim.tbl_extend("force", loaders[self].config, opts) or loaders[self].config
  local str = { [false] = 0, [true] = 1 }
  return ("%d%d|%s|%s%s"):format(str[config.lazy], str[config.detect_base], config.base_dir, config.prefix, modname)
end

---
---Load target module
---
---@param self LazyLoader Loader instance
---@param modname string Module name to load
---@param opts? LazyLoader.Config Optional config override
---@return any # Loaded module
local function load(self, modname, opts)
  local loader = loaders[self]
  local key = get_cache_key(self, modname, opts)
  local cache = loader.cache[key] or {}
  loader.cache[key] = cache

  -- Return immediately if already loaded
  if cache.loaded then return cache.module end

  -- Merge configurations
  cache.config = vim.tbl_extend("force", loader.config, opts or {})

  if not cache.proxy then
    -- First-time initialization
    cache.base = cache.config.detect_base and detect_base(loader.caller_dir, cache.config) or ""
    cache.modname = cache.base .. cache.config.prefix .. modname
    cache.origin_mod = modname
  end

  -- Trigger pre-load callback
  if cache.config.on_load then cache.config.on_load(cache.modname) end

  -- Actual module loading
  local ok, result = pcall(require, cache.modname)
  cache.loaded = true -- Mark as loaded even if failed
  if not ok then error(("Failed to load module '%s': %s"):format(cache.modname, result)) end

  -- Cache result and trigger post-load callback
  cache.module = result
  if cache.config.on_loaded then cache.config.on_loaded(cache.modname) end

  return cache.module
end

--#endregion

--#region Proxy Mechanism ------------------------------------------------------

---@class LazyLoader.Proxy: table Lazy loading proxy object

-- Proxy metatable for lazy access
local LazyProxy = {
  __index = function(t, k)
    local data = proxy_registry[t]
    if not data then error("Proxy registry corrupted for key: " .. tostring(k), 2) end

    -- Trigger actual loading on first access
    local cache = data.loader.cache[data.cache_key]
    if not cache.loaded then load(data.manager, data.modname) end

    -- Cache accessed properties
    local value = cache.module[k]
    rawset(t, k, value)
    return value
  end,

  __newindex = function()
    error("Cannot modify read-only proxy", 2)
  end,
}

---
---Create lazy access proxy for module
---
---@param self LazyLoader Loader instance
---@param modname string Module name to proxy
---@param opts? LazyLoader.Config Optional config override
---@return LazyLoader.Proxy # Read-only proxy table
local function lazy(self, modname, opts)
  local loader = loaders[self]
  local key = get_cache_key(self, modname, opts)
  local cache = loader.cache[key] or {}
  loader.cache[key] = cache

  -- Return existing proxy if already created
  if cache.proxy then return cache.proxy end

  -- Initialize lazy loading configuration
  cache.config = vim.tbl_extend("force", loader.config, opts or {})
  cache.loaded = false -- Mark as unloaded

  -- Calculate module identifiers
  cache.base = cache.config.detect_base and detect_base(loader.caller_dir, cache.config) or ""
  cache.modname = cache.base .. cache.config.prefix .. modname
  cache.origin_mod = modname

  -- Create proxy object and registry entry
  cache.proxy = {}
  proxy_registry[cache.proxy] = {
    manager = self,
    modname = modname,
    cache_key = key,
    loader = loader,
  }

  -- Set up proxy metatable for lazy access
  return setmetatable(cache.proxy, LazyProxy)
end

--#endregion

--#region Cache Management -----------------------------------------------------

---
---Handle individual cache entry reset
---
---@param cache_entry table<string, LazyLoader.ModuleCache> Cache storage table
---@param key string Cache key identifier
local function on_reset(cache_entry, key)
  local cache = cache_entry[key]

  -- Remove module from package.loaded to force reload next time
  package.loaded[cache.modname] = nil

  -- Clean up proxy reference if exists
  if cache.proxy then proxy_registry[cache.proxy] = nil end

  -- Purge cache entry completely
  cache_entry[key] = nil
end

---
---Reset all cached modules matching optional filter
---
---@param self LazyLoader Loader instance
---@param opts? LazyLoader.Config Configuration for cache matching
---@param after_reset? fun(cache: LazyLoader.ModuleCache) Post-reset callback
local function reset_all(self, opts, after_reset)
  local loader = loaders[self]

  -- Generate pattern filter from options
  local key_filter = opts and get_cache_key(self, "", opts)

  -- Iterate through all cached modules
  for cached_key, cache in pairs(loader.cache) do
    -- Check if current entry matches filter pattern
    if key_filter == nil or vim.startswith(cached_key, key_filter) then
      -- Execute core reset logic
      on_reset(loader.cache, cached_key)

      -- Run post-reset callback if provided
      if after_reset then after_reset(cache) end
    end
  end
end

---
---Reset cached module(s)
---
---@param modname? string Module name to reset (nil for all modules)
---@param opts? LazyLoader.Config Config for cache matching
function LazyLoader:reset(modname, opts)
  vim.validate { modname = { modname, "string", true }, opts = { opts, "table", true } }

  -- Handle batch reset when no module specified
  if modname == nil then
    reset_all(self, opts)
    return
  end

  local key = get_cache_key(self, modname, opts)
  if not loaders[self].cache[key] then return end

  -- Execute core reset logic
  on_reset(loaders[self].cache, key)
end

---
---Reload cached module(s)
---
---@param modname? string Module name to reload (nil for all modules)
---@param opts? LazyLoader.Config Config for cache matching
function LazyLoader:reload(modname, opts)
  vim.validate { modname = { modname, "string", true }, opts = { opts, "table", true } }

  -- Batch reload: reset and reload all matching modules
  if modname == nil then
    reset_all(self, opts, function(cache)
      -- Re-initialize module with original parameters
      self(cache.origin_mod, cache.config)
    end)
    return
  end

  -- Single module reload flow
  self:reset(modname, opts)

  -- Trigger fresh load with original parameters
  self(modname, opts)
end

--#endregion

--#region Metamethods ----------------------------------------------------------

---
---Main loader invocation handler
---
---@param modname string Module name to load
---@param opts? LazyLoader.Config Optional config override
---@return any # Loaded module or proxy
function LazyLoader:__call(modname, opts)
  vim.validate { modname = { modname, "string" }, opts = { opts, "table", true } }
  return loaders[self].config.lazy and lazy(self, modname, opts) or load(self, modname, opts)
end

--#endregion

return LazyLoader
