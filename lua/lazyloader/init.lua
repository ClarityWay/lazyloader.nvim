local M = {}

local LazyLoader = require("lazyloader.loader")

-- Preconfigured loader instances
local loader, lazy_loader

--#region Public API -----------------------------------------------------------

---
---Configure global defaults and reset preconfigured instances
---
---@param opts? LazyLoader.Config
function M.setup(opts)
  LazyLoader.setup(opts)

  loader = loader or LazyLoader.new { lazy = false, detect_base = false }
  lazy_loader = lazy_loader or LazyLoader.new { detect_base = false }
end

---@see LazyLoader.new
M.new = LazyLoader.new

---
---Eager load module
---
---@param modname string Module name to load
---@param opts? LazyLoader.Config Optional configuration override
---@return any # Loaded module
function M.load(modname, opts)
  if not loader then M.setup() end
  return loader(modname, opts)
end

---
---Create lazy-loaded proxy for a module
---
---@param modname string Module name to lazy load
---@param opts? LazyLoader.Config Optional configuration override
---@return LazyLoader.Proxy # Lazy loading proxy table
function M.lazy(modname, opts)
  if not lazy_loader then M.setup() end
  return lazy_loader(modname, opts)
end

--#endregion

return M
