-- CC:Tweaked 1.120.0 Crafty Turtle Factory OS
--
-- This program intentionally does not query Minecraft's Recipe API.
-- Register a recipe by placing one real recipe in the Crafty Turtle grid,
-- then using TEST & REGISTER on the monitor.
--
-- Run on the Crafty Turtle. Materials are read from all STORAGE inventories
-- visible through the CC:T Wired Modem network. This program does not use
-- turtle.suckUp() for material discovery.
--   factory scan
--   factory dashboard
--   factory recipe list|capture|show|remove
--   factory stock [search <text>]
--   factory craft <recipe> [count|auto]
--   factory queue list|clear

local cfg = {
  storage_file = "factory_storage.db",
  turtle_inventory = "AUTO",  -- optional generic inventory view of this turtle
  output_inventory = "AUTO",  -- optional explicit OUTPUT inventory name
  staging_inventory = "AUTO", -- Wired Network destination name, or AUTO
  staging_side = "top",       -- local Turtle side used by turtle.suckUp()
  craft_peripheral = "AUTO",   -- normally left=workbench/craft
  monitor = "AUTO",
  gpu = "",                   -- disabled: use the CC:T Advanced Monitor path
  gpu_resolution = 64,         -- Tom's Bitmap Monitor resolution per block
  keyboard = "AUTO",          -- optional Tom's Peripherals keyboard
  inventory_manager = "AUTO",  -- optional Advanced Peripherals hand reader
  output_side = "down",        -- finished products leave with turtle.dropDown()

  recipe_file = "factory_recipes.db",
  queue_file = "factory_queue.db",
  auto_file = "factory_auto.db",
  log_file = "factory.log",

  refresh_seconds = 1,
  auto_poll_seconds = 0.2,
  page_size = 6,
  batch_limit = 64,
  target_stock = 32,
  output_slot = 16,
  github_api = "https://api.github.com/repos/kaede050492/crafty-turtle-factory-os/commits/main",
}

-- The physical Crafty Turtle grid is not logical slots 1..9.
local CRAFT_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local NON_GRID_SLOTS = { 4, 8, 12, 13, 14, 15, 16 }

local state = {
  page = "home",
  message = "",
  error = "",
  selected = nil,
  target_value = nil,
  preview = nil,
  buttons = {},
  monitor_name = nil,
  recipes_page = 1,
  stock_page = 1,
  stock_query = "",
  stock_sort = "name",
  stock_show_ids = true,
  queue_job = nil,
  auto_global = false,
  auto_current = nil,
  auto_blocked = false,
  timer = nil,
  storage_page = 1,
  ui_dirty = true,
  display_mode = "monitor",
  keyboard_name = nil,
  keyboard_native = false,
  gpu_name = nil,
}

-- wget only transfers the raw Lua file, so the running program also checks
-- GitHub's public commit endpoint and shows the exact current main revision.
-- This is informational only: a failed HTTP request must never stop Factory.
local buildInfo = {
  commit = "unavailable",
  time = "unavailable",
}

-- AUTO is intentionally disabled for every recipe until the user enables it.
-- This avoids competing recipes consuming the same input after an upgrade or
-- a database migration.
local autoState = {
  global = false,
  recipes = {},
  blocked = false,
  cursor = nil,
}

-- The monitor and AUTO planner share this cache. AUTO refreshes it with
-- inventory.list(), which is cheap and contains names/counts. getItemDetail()
-- is only used when the stock page needs a display name.
local stockCache = {
  signature = "",
  inventories = {},
  outputInventories = {},
  totals = {},
  outputTotals = {},
  displayNames = {},
  details = {},
  entries = {},
  displayLoaded = false,
  outputCapacities = {},
  usedSlots = 0,
  totalSlots = 0,
  updated = 0,
  reason = nil,
}

local P = {
  resolved = false,
  craft_name = nil,
  craft = nil,
  monitor_name = nil,
  monitor = nil,
  gpu_name = nil,
  gpu = nil,
  keyboard_name = nil,
  keyboard = nil,
  manager_name = nil,
  manager = nil,
  turtle_inventory_name = nil,
  turtle_inventory = nil,
  staging_local_name = nil,
  staging_local = nil,
  staging_network_name = nil,
  staging_network = nil,
  -- Compatibility alias: this is always the Wired Network name.
  staging_name = nil,
  staging = nil,
  inventories = {},
  storage = {},
  outputs = {},
}

local STORAGE_ROLES = { "STORAGE", "STAGING", "CRAFTER", "OUTPUT", "IGNORE" }
local storageState = {
  roles = {},
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function configured(value)
  return type(value) == "string" and value ~= "" and value ~= "AUTO"
end

local function now()
  return os.epoch and os.epoch("utc") or 0
end

local function log(level, message)
  local line = ("[%d] [%s] %s\n"):format(now(), level, tostring(message))
  local ok, handle = pcall(fs.open, cfg.log_file, "a")
  if ok and handle then
    handle.write(line)
    handle.close()
  end
end

local function setMessage(message, isError)
  state.message = tostring(message or "")
  state.error = isError and state.message or ""
  state.ui_dirty = true
  log(isError and "ERROR" or "INFO", state.message)
end

local function updateBuildInfo()
  if type(http) ~= "table" or type(http.get) ~= "function" then
    return false, "HTTP API unavailable"
  end
  local ok, response = pcall(http.get, cfg.github_api, {
    ["User-Agent"] = "CC-T Factory OS",
    ["Accept"] = "application/vnd.github+json",
  })
  if not ok or not response then
    return false, tostring(response or "GitHub API connection failed")
  end
  local readOk, body = pcall(response.readAll)
  pcall(response.close)
  if not readOk or type(body) ~= "string" then
    return false, "GitHub API response could not be read"
  end
  local commit = body:match('"sha"%s*:%s*"([0-9a-fA-F]+)"')
  local commitTime = body:match('"committer"%s*:%s*{.-"date"%s*:%s*"([^"]+)"')
    or body:match('"date"%s*:%s*"([^"]+)"')
  if not commit then
    return false, "GitHub API did not return a commit SHA"
  end
  buildInfo.commit = commit
  buildInfo.time = commitTime or "unknown"
  state.ui_dirty = true
  return true
end

local function hasMethod(name, method)
  local methods = peripheral.getMethods(name) or {}
  for _, candidate in ipairs(methods) do
    if candidate == method then return true end
  end
  return false
end

local function isInventory(name)
  return hasMethod(name, "list") and
    (hasMethod(name, "pushItems") or hasMethod(name, "pullItems"))
end

local function isTransferInventory(name)
  return isInventory(name) and (hasMethod(name, "pushItems") or hasMethod(name, "pullItems"))
end

-- Tom's Peripherals does not require a single fixed peripheral type name for
-- the GPU, so identify it by the documented methods we actually use.  The
-- method check prevents a random peripheral exposing getSize() from being
-- selected as a display.
local function typeMatches(name, expected)
  for _, actual in ipairs({ peripheral.getType(name) }) do
    if actual == expected then return true end
  end
  return false
end

local function isTomGpu(name)
  return hasMethod(name, "refreshSize")
    and hasMethod(name, "getSize")
    and hasMethod(name, "sync")
end

local function isTomKeyboard(name)
  return typeMatches(name, "keyboard") or hasMethod(name, "setFireNativeEvents")
end

local function sortedPeripheralNames()
  local names = peripheral.getNames()
  table.sort(names)
  return names
end

local function resetPeripherals()
  P.resolved = false
  P.craft = nil
  P.monitor = nil
  P.gpu = nil
  P.keyboard = nil
  P.gpu_name = nil
  P.keyboard_name = nil
  P.manager = nil
  P.turtle_inventory_name = nil
  P.turtle_inventory = nil
  P.staging_local_name = nil
  P.staging_local = nil
  P.staging_network_name = nil
  P.staging_network = nil
  P.staging_name = nil
  P.staging = nil
  P.inventories = {}
  P.storage = {}
  P.outputs = {}
end

local function validRole(role)
  for _, value in ipairs(STORAGE_ROLES) do
    if role == value then return true end
  end
  return false
end

local function defaultRole(name)
  if name == cfg.output_inventory and cfg.output_inventory ~= "AUTO" then
    return "OUTPUT"
  end
  if name == cfg.output_side then
    return "OUTPUT"
  end
  if name == cfg.staging_side then
    return "STAGING"
  end
  if name == P.staging_name and configured(P.staging_name) then
    return "STAGING"
  end
  if name == cfg.staging_inventory and configured(cfg.staging_inventory) then
    return "STAGING"
  end
  if name == P.turtle_inventory_name then
    return "IGNORE"
  end
  return "STORAGE"
end

local function roleFor(name)
  if name == cfg.staging_side then return "STAGING" end
  if name == P.staging_name and configured(P.staging_name) then return "STAGING" end
  if name == cfg.staging_inventory and configured(cfg.staging_inventory) then
    return "STAGING"
  end
  local role = storageState.roles[name]
  if validRole(role) then return role end
  return defaultRole(name)
end

local function isTurtleLike(name)
  return tostring(name):lower():find("turtle", 1, true) ~= nil
    or typeMatches(name, "turtle") or typeMatches(name, "computer")
    or typeMatches(name, "monitor") or typeMatches(name, "modem")
end

local function scanInventories()
  local inventories = {}
  local storage = {}
  local outputs = {}
  for _, name in ipairs(sortedPeripheralNames()) do
    if not isTurtleLike(name) and isTransferInventory(name) then
      local object = peripheral.wrap(name)
      if object then
        local role = roleFor(name)
        local entry = { name = name, object = object, role = role }
        inventories[#inventories + 1] = entry
        if role == "STORAGE" then storage[#storage + 1] = entry end
        if role == "OUTPUT" then outputs[#outputs + 1] = entry end
      end
    end
  end
  P.inventories, P.storage, P.outputs = inventories, storage, outputs
  return inventories
end

local function resolvePeripherals(force)
  if P.resolved and not force then return P end
  if type(turtle) ~= "table" then
    error("factory.luaはCrafty Turtle上で実行してください。", 0)
  end

  local craftName = cfg.craft_peripheral
  if craftName == "AUTO" then
    if peripheral.isPresent("left") and hasMethod("left", "craft") then
      craftName = "left"
    else
      for _, name in ipairs(sortedPeripheralNames()) do
        if hasMethod(name, "craft") then
          craftName = name
          break
        end
      end
    end
  end
  local craft = configured(craftName) and peripheral.wrap(craftName) or nil
  if craft and type(craft.craft) ~= "function" then craft = nil end
  -- Some installations expose the crafting-table upgrade as turtle.craft()
  -- instead of a left-side workbench peripheral. Support both real APIs.
  if not craft and type(turtle.craft) ~= "function" then
    error("Crafty Turtleのcraft()またはworkbench peripheralが見つかりません。", 0)
  end

  local monitorName = cfg.monitor
  if monitorName == "AUTO" then
    for _, name in ipairs(sortedPeripheralNames()) do
      if typeMatches(name, "monitor") then
        monitorName = name
        break
      end
    end
  end
  local monitor = configured(monitorName) and peripheral.wrap(monitorName) or nil

  local gpuName = cfg.gpu
  if gpuName == "AUTO" then
    for _, name in ipairs(sortedPeripheralNames()) do
      if isTomGpu(name) then
        gpuName = name
        break
      end
    end
  end
  local gpu = configured(gpuName) and peripheral.wrap(gpuName) or nil
  if gpu and not isTomGpu(gpuName) then gpu = nil end

  local keyboardName = cfg.keyboard
  if keyboardName == "AUTO" then
    for _, name in ipairs(sortedPeripheralNames()) do
      if isTomKeyboard(name) then
        keyboardName = name
        break
      end
    end
  end
  local keyboard = configured(keyboardName) and peripheral.wrap(keyboardName) or nil
  if keyboard and not isTomKeyboard(keyboardName) then keyboard = nil end
  local keyboardNative = false
  if keyboard and type(keyboard.setFireNativeEvents) == "function" then
    keyboardNative = pcall(keyboard.setFireNativeEvents, true)
    if not keyboardNative then
      log("WARN", "Tom's Keyboard native events could not be enabled")
    end
  end

  local managerName = cfg.inventory_manager
  if managerName == "AUTO" then
    for _, name in ipairs(sortedPeripheralNames()) do
      if typeMatches(name, "inventory_manager")
        or typeMatches(name, "inventoryManager")
        or hasMethod(name, "getItemInHand") then
        managerName = name
        break
      end
    end
  end
  local manager = configured(managerName) and peripheral.wrap(managerName) or nil

  P.resolved = true
  P.craft_name, P.craft = configured(craftName) and craftName or nil, craft
  P.monitor_name, P.monitor = configured(monitorName) and monitorName or nil, monitor
  P.gpu_name, P.gpu = configured(gpuName) and gpuName or nil, gpu
  P.keyboard_name, P.keyboard = configured(keyboardName) and keyboardName or nil, keyboard
  P.manager_name, P.manager = configured(managerName) and managerName or nil, manager
  state.gpu_name = P.gpu_name
  state.keyboard_name = P.keyboard_name
  state.keyboard_native = keyboardNative
  state.display_mode = P.gpu and "gpu" or "monitor"
  scanInventories()

  local turtleInventoryName = cfg.turtle_inventory
  if turtleInventoryName == "AUTO" then
    for _, name in ipairs(sortedPeripheralNames()) do
      if typeMatches(name, "turtle") and isTransferInventory(name) then
        turtleInventoryName = name
        break
      end
    end
  end
  local turtleInventory = configured(turtleInventoryName) and peripheral.wrap(turtleInventoryName) or nil
  if not turtleInventory or not isTransferInventory(turtleInventoryName) then
    turtleInventoryName, turtleInventory = nil, nil
  end
  P.turtle_inventory_name, P.turtle_inventory = turtleInventoryName, turtleInventory

  -- STAGING has two deliberately separate identities:
  --   staging_local_name   = "top" on the Turtle, for suckUp/list()
  --   staging_network_name = e.g. "minecraft:barrel_13", for pushItems()
  -- Passing the local side to pushItems() causes "Target 'top' does not
  -- exist", even though turtle.suckUp("top") is correct.
  P.staging_local_name, P.staging_local = nil, nil
  P.staging_network_name, P.staging_network = nil, nil
  P.staging_name, P.staging = nil, nil

  local stagingLocalName = cfg.staging_side
  local stagingLocal = peripheral.isPresent(stagingLocalName)
    and peripheral.wrap(stagingLocalName) or nil
  if not stagingLocal or not isTransferInventory(stagingLocalName) then
    stagingLocal = nil
    log("WARN", "STAGING local side is unavailable: " .. tostring(stagingLocalName))
  end

  local stagingNetworkName = nil
  if configured(cfg.staging_inventory) and cfg.staging_inventory ~= stagingLocalName then
    if isTransferInventory(cfg.staging_inventory) then
      stagingNetworkName = cfg.staging_inventory
    else
      log("WARN", "Configured STAGING network inventory is unavailable: " ..
        tostring(cfg.staging_inventory))
    end
  elseif configured(cfg.staging_inventory) then
    log("WARN", "staging_inventory must be a Wired Network name, not " ..
      tostring(stagingLocalName))
  end

  -- AUTO resolves the network endpoint from the persisted STAGING role.
  -- The local side is skipped: it is valid for suckUp(), never for a network
  -- push destination.
  if not stagingNetworkName then
    for _, name in ipairs(sortedPeripheralNames()) do
      if name ~= stagingLocalName and roleFor(name) == "STAGING"
        and isTransferInventory(name) then
        stagingNetworkName = name
        break
      end
    end
  end

  local stagingNetwork = stagingNetworkName and peripheral.wrap(stagingNetworkName) or nil
  if stagingNetworkName and (not stagingNetwork or not isTransferInventory(stagingNetworkName)
    or type(stagingNetwork.pushItems) ~= "function") then
    log("WARN", "STAGING network endpoint is unavailable: " .. tostring(stagingNetworkName))
    stagingNetworkName, stagingNetwork = nil, nil
  end

  P.staging_local_name, P.staging_local = stagingLocal and stagingLocalName or nil, stagingLocal
  P.staging_network_name, P.staging_network = stagingNetworkName, stagingNetwork
  -- Existing code and UI use staging_name; its meaning is now explicitly the
  -- network destination name, never the local Turtle side.
  P.staging_name, P.staging = stagingNetworkName, stagingLocal
  scanInventories()
  state.monitor_name = P.monitor_name
  return P
end

local function stagingSummary()
  return tostring(P.staging_local_name or "unavailable") .. " -> " ..
    tostring(P.staging_network_name or "unavailable")
end

local function scan()
  print("--- Factory peripheral scan ---")
  for _, name in ipairs(sortedPeripheralNames()) do
    local types = { peripheral.getType(name) }
    local methods = peripheral.getMethods(name) or {}
    table.sort(methods)
    print(name)
    print("  type: " .. table.concat(types, ", "))
    print("  methods: " .. (#methods > 0 and table.concat(methods, ", ") or "(none)"))
    if isTransferInventory(name) then
      print("  factory role: " .. roleFor(name))
    end
  end
  local ok, p = pcall(resolvePeripherals, true)
  if ok then
    print("turtle inventory target: " .. tostring(p.turtle_inventory_name or "unavailable"))
    print("staging local: " .. tostring(p.staging_local_name or "unavailable"))
    print("staging network: " .. tostring(p.staging_network_name or "unavailable"))
    print("STORAGE inventories: " .. tostring(#p.storage))
    print("Tom's GPU: " .. tostring(p.gpu_name or "unavailable"))
    if p.gpu then
      local gpuOk, width, height = pcall(p.gpu.getSize)
      print("GPU size: " .. (gpuOk and (tostring(width) .. "x" .. tostring(height)) or "unavailable"))
      print("GPU window: " .. (hasMethod(p.gpu_name, "createWindow") and "available" or "unavailable"))
    end
    print("Tom's keyboard: " .. tostring(p.keyboard_name or "unavailable") ..
      (state.keyboard_native and " (native)" or " (prefixed/unknown)"))
  else
    print("factory resolve: " .. tostring(p))
  end
  print("Crafty grid: 1 2 3 / 5 6 7 / 9 10 11")
end

local function writeAtomic(path, value)
  local temp = path .. ".tmp"
  local backup = path .. ".bak"
  local handle = fs.open(temp, "w")
  if not handle then error("DB一時ファイルを開けません: " .. temp, 0) end
  handle.write(textutils.serialize(value))
  handle.close()

  if fs.exists(backup) then fs.delete(backup) end
  if fs.exists(path) then
    local ok, reason = pcall(fs.move, path, backup)
    if not ok then
      fs.delete(temp)
      error("DBバックアップ作成に失敗しました: " .. tostring(reason), 0)
    end
  end
  local ok, reason = pcall(fs.move, temp, path)
  if not ok then
    if fs.exists(backup) then fs.move(backup, path) end
    error("DB置換に失敗しました: " .. tostring(reason), 0)
  end
  if fs.exists(backup) then fs.delete(backup) end
end

local function readTable(path, fallback)
  if not fs.exists(path) then return fallback end
  local handle = fs.open(path, "r")
  if not handle then return fallback end
  local raw = handle.readAll()
  handle.close()
  if not raw or raw == "" then return fallback end
  local ok, value = pcall(textutils.unserialize, raw)
  if ok and type(value) == "table" then return value end
  local backup = path .. ".bak"
  if fs.exists(backup) then
    local backupHandle = fs.open(backup, "r")
    local backupRaw = backupHandle and backupHandle.readAll() or ""
    if backupHandle then backupHandle.close() end
    local backupOk, backupValue = pcall(textutils.unserialize, backupRaw)
    if backupOk and type(backupValue) == "table" then
      log("WARN", "破損したDBの代わりにバックアップを使用: " .. path)
      return backupValue
    end
  end
  log("WARN", "DBを読み込めないため空の初期値を使用: " .. path)
  return fallback
end

local function saveStorageConfig()
  writeAtomic(cfg.storage_file, { roles = copy(storageState.roles) })
end

local function loadStorageConfig()
  local raw = readTable(cfg.storage_file, {})
  storageState.roles = type(raw.roles) == "table" and raw.roles or {}
end

local function setStorageRole(name, role)
  if not configured(name) then return false, "inventory名が必要です。" end
  role = tostring(role or ""):upper()
  if not validRole(role) then
    return false, "roleは STORAGE / STAGING / CRAFTER / OUTPUT / IGNORE のいずれかです。"
  end
  if name == cfg.staging_side and role ~= "STAGING" then
    return false, cfg.staging_side .. "はSTAGING固定です。"
  end
  storageState.roles[name] = role
  saveStorageConfig()
  resetPeripherals()
  resolvePeripherals(true)
  return true
end

local function saveAuto()
  writeAtomic(cfg.auto_file, {
    global = autoState.global == true,
    blocked = autoState.blocked == true,
    cursor = autoState.cursor,
    recipes = copy(autoState.recipes),
  })
end

local function loadAuto()
  local raw = readTable(cfg.auto_file, {})
  autoState.global = raw.global == true
  autoState.blocked = raw.blocked == true
  autoState.cursor = type(raw.cursor) == "string" and raw.cursor or nil
  autoState.recipes = type(raw.recipes) == "table" and raw.recipes or {}
  state.auto_global = autoState.global
  state.auto_blocked = autoState.blocked
end

local function recipeAutoEnabled(name)
  return autoState.recipes[name] == true
end

local function enabledAutoCount(recipes)
  local count = 0
  for name in pairs(recipes or {}) do
    if recipeAutoEnabled(name) then count = count + 1 end
  end
  return count
end

local function itemDetail(slot)
  local ok, detail = pcall(turtle.getItemDetail, slot, true)
  if not ok then ok, detail = pcall(turtle.getItemDetail, slot) end
  if ok and type(detail) == "table" and detail.name then return detail end
  return nil
end

local function inventorySnapshot()
  local result = {}
  for slot = 1, 16 do result[slot] = itemDetail(slot) or "" end
  return result
end

local function slotEmpty(snapshot, slot)
  return not snapshot[slot] or snapshot[slot] == ""
end

local function allNonGridEmpty(snapshot)
  for _, slot in ipairs(NON_GRID_SLOTS) do
    if not slotEmpty(snapshot, slot) then return false, slot end
  end
  return true
end

local function allTurtleEmpty(snapshot)
  for slot = 1, 16 do
    if not slotEmpty(snapshot, slot) then return false, slot end
  end
  return true
end

local function itemName(value)
  if type(value) == "table" then return value.name or value.item or value.id end
  return value
end

local function itemMatches(detail, expected)
  return detail and expected and itemName(detail) == itemName(expected)
end

local function gridSnapshot()
  local grid = {}
  for logical, physical in ipairs(CRAFT_SLOTS) do
    local detail = itemDetail(physical)
    if detail then
      local entry = copy(detail)
      -- A crafting grid slot represents one ingredient per craft.
      entry.placed = entry.count or 1
      entry.count = 1
      grid[logical] = entry
    else
      grid[logical] = ""
    end
  end
  return grid
end

local function emptyGrid()
  local grid = {}
  for logical = 1, #CRAFT_SLOTS do grid[logical] = "" end
  return grid
end

local function hasIngredient(grid)
  for _, entry in ipairs(grid) do
    if entry ~= "" and itemName(entry) then return true end
  end
  return false
end

local function gridIngredients(recipe)
  local result = {}
  for logical, entry in ipairs(recipe.grid or {}) do
    if type(entry) == "table" and entry.name then
      result[#result + 1] = {
        logical = logical,
        physical = CRAFT_SLOTS[logical],
        item = entry.name,
        count = math.max(1, math.floor(tonumber(entry.count) or 1)),
        detail = entry,
      }
    end
  end
  return result
end

local function recipeOutput(recipe)
  return recipe and recipe.output or nil
end

local function recipeName(recipe)
  return recipe and recipe.name or "?"
end

local function shortName(value, width)
  local text = tostring(value or "")
  text = text:gsub("^.-:", "")
  if #text > width then return text:sub(1, math.max(1, width - 1)) .. "~" end
  return text
end

local function recipeSummary(recipe)
  local counts = {}
  for _, entry in ipairs(gridIngredients(recipe)) do
    counts[entry.item] = (counts[entry.item] or 0) + entry.count
  end
  local names = {}
  for name in pairs(counts) do names[#names + 1] = name end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do parts[#parts + 1] = shortName(name, 18) .. "*" .. counts[name] end
  return table.concat(parts, ", ")
end

local function normalizeRecipe(recipe)
  if type(recipe) ~= "table" or type(recipe.name) ~= "string" then return nil end
  if type(recipe.output) ~= "table" or type(recipe.output.name) ~= "string" then return nil end
  if type(recipe.grid) ~= "table" then return nil end
  local result = copy(recipe)
  result.grid = {}
  for logical = 1, 9 do
    local entry = recipe.grid[logical]
    if type(entry) == "table" and type(entry.name) == "string" then
      entry = copy(entry)
      entry.count = math.max(1, math.floor(tonumber(entry.count) or 1))
      result.grid[logical] = entry
    else
      result.grid[logical] = ""
    end
  end
  result.output = copy(recipe.output)
  result.output.count = math.max(1, math.floor(tonumber(result.output.count) or 1))
  result.output.maxCount = math.max(1, math.floor(tonumber(result.output.maxCount) or 64))
  result.target = math.max(0, math.floor(tonumber(result.target) or cfg.target_stock))
  return result
end

local function loadRecipes()
  local raw = readTable(cfg.recipe_file, {})
  local result = {}
  for key, value in pairs(raw) do
    local recipe = normalizeRecipe(value)
    if recipe then
      result[recipe.name or key] = recipe
    else
      log("WARN", "不正なレシピを無視: " .. tostring(key))
    end
  end
  return result
end

local function saveRecipes(recipes)
  writeAtomic(cfg.recipe_file, recipes)
end

local function recipeKeys(recipes)
  local result = {}
  for name in pairs(recipes) do result[#result + 1] = name end
  table.sort(result)
  return result
end

local function findRecipe(recipes, name)
  if not name then return nil end
  if recipes[name] then return recipes[name] end
  for _, recipe in pairs(recipes) do
    if recipe.output.name == name then return recipe end
  end
  return nil
end

local function uniqueRecipeName(recipes, output)
  local base = shortName(output.name, 32)
  if not recipes[base] then return base end
  if recipes[base].output.name == output.name then return base end
  local index = 2
  while recipes[base .. "_" .. index] do index = index + 1 end
  return base .. "_" .. index
end

local function inventoryStacks(peripheralObject)
  if not peripheralObject then return {}, "inventory未接続です。" end
  if type(peripheralObject.list) == "function" then
    local ok, list = pcall(peripheralObject.list)
    if ok and type(list) == "table" then return list end
  end
  return {}, "inventory.list()を読み取れません。"
end

local function listSignature(name, stacks)
  local slots = {}
  for slot in pairs(stacks or {}) do slots[#slots + 1] = slot end
  table.sort(slots)
  local parts = {}
  for _, slot in ipairs(slots) do
    local stack = stacks[slot]
    parts[#parts + 1] = ("%s:%s:%s:%s"):format(
      tostring(name),
      tostring(slot), tostring(stack and stack.name or ""), tostring(stack and stack.count or 0)
    )
  end
  return table.concat(parts, "|")
end

local function rebuildStockEntries()
  local entries = {}
  for name, count in pairs(stockCache.totals) do
    entries[#entries + 1] = {
      name = name,
      displayName = stockCache.displayNames[name],
      count = count,
    }
  end
  stockCache.entries = entries
end

local function refreshStockCache(loadDisplayNames)
  resolvePeripherals()
  scanInventories()
  local inventories = {}
  local outputInventories = {}
  local signatureParts = {}
  local reasons = {}
  local usedSlots, totalSlots = 0, 0
  for _, entry in ipairs(P.storage) do
    local stacks, reason = inventoryStacks(entry.object)
    inventories[entry.name] = {
      name = entry.name,
      object = entry.object,
      stacks = stacks,
      reason = reason,
    }
    signatureParts[#signatureParts + 1] = listSignature(entry.name, stacks)
    if reason then reasons[#reasons + 1] = entry.name .. ": " .. reason end
    for _ in pairs(stacks) do usedSlots = usedSlots + 1 end
    if type(entry.object.size) == "function" then
      local sizeOk, size = pcall(entry.object.size)
      if sizeOk and type(size) == "number" then totalSlots = totalSlots + size end
    end
  end
  -- OUTPUT is not part of the material STOCK page, but it is part of the
  -- finished-product total used by Target AUTO control. list() is cheap and
  -- avoids getItemDetail() calls during the fast polling loop.
  for _, entry in ipairs(P.outputs) do
    if not inventories[entry.name] and not outputInventories[entry.name] then
      local stacks, reason = inventoryStacks(entry.object)
      outputInventories[entry.name] = {
        name = entry.name,
        object = entry.object,
        stacks = stacks,
        reason = reason,
      }
      signatureParts[#signatureParts + 1] = "OUTPUT:" .. listSignature(entry.name, stacks)
      if reason then reasons[#reasons + 1] = entry.name .. ": " .. reason end
    end
  end
  table.sort(signatureParts)
  local signature = table.concat(signatureParts, "|")
  local reason = #reasons > 0 and table.concat(reasons, "; ") or nil
  local needsNames = loadDisplayNames and not stockCache.displayLoaded
  if signature == stockCache.signature and reason == stockCache.reason and not needsNames then
    stockCache.updated = now()
    stockCache.outputCapacities = {}
    return stockCache
  end

  local totals = {}
  local outputTotals = {}
  local displayNames = {}
  for _, inventory in pairs(inventories) do
    for slot, stack in pairs(inventory.stacks) do
      if stack and stack.name then
        totals[stack.name] = (totals[stack.name] or 0) + (stack.count or 0)
        if stack.displayName then displayNames[stack.name] = stack.displayName end
      end
    end
  end

  for _, inventory in pairs(outputInventories) do
    for _, stack in pairs(inventory.stacks) do
      if stack and stack.name then
        outputTotals[stack.name] = (outputTotals[stack.name] or 0) + (stack.count or 0)
      end
    end
  end

  for name in pairs(totals) do
    local detail = stockCache.details[name]
    if detail and detail.displayName and not displayNames[name] then
      displayNames[name] = detail.displayName
    end
  end

  if loadDisplayNames then
    for _, inventory in pairs(inventories) do
      if type(inventory.object.getItemDetail) == "function" then
        for slot, stack in pairs(inventory.stacks) do
          if stack and stack.name and not stockCache.details[stack.name] then
            local ok, detail = pcall(inventory.object.getItemDetail, slot)
            if ok and type(detail) == "table" and detail.name then
              stockCache.details[detail.name] = detail
              if detail.displayName then displayNames[detail.name] = detail.displayName end
            end
          end
        end
      end
    end
  end

  stockCache.signature = signature
  stockCache.inventories = inventories
  stockCache.outputInventories = outputInventories
  stockCache.totals = totals
  stockCache.outputTotals = outputTotals
  stockCache.displayNames = displayNames
  stockCache.displayLoaded = loadDisplayNames == true
  stockCache.outputCapacities = {}
  stockCache.usedSlots = usedSlots
  stockCache.totalSlots = totalSlots
  stockCache.updated = now()
  stockCache.reason = reason
  rebuildStockEntries()
  return stockCache
end

local function stockEntries(query)
  local cache = refreshStockCache(true)
  local entries = {}
  local needle = query and query:lower() or ""
  for _, entry in ipairs(cache.entries) do
    local display = tostring(entry.displayName or ""):lower()
    if needle == "" or entry.name:lower():find(needle, 1, true)
      or display:find(needle, 1, true) then
      entries[#entries + 1] = copy(entry)
    end
  end
  if state.stock_sort == "count" then
    table.sort(entries, function(a, b)
      if a.count == b.count then return a.name < b.name end
      return a.count > b.count
    end)
  else
    table.sort(entries, function(a, b) return a.name < b.name end)
  end
  return entries, cache.reason
end

local function stockCount(name, cache)
  cache = cache or refreshStockCache(false)
  return math.max(0, math.floor(tonumber(cache.totals[name]) or 0))
end

local function finishedStockCount(name, cache)
  cache = cache or refreshStockCache(false)
  local storageCount = tonumber(cache.totals[name]) or 0
  local outputCount = tonumber(cache.outputTotals and cache.outputTotals[name]) or 0
  return math.max(0, math.floor(storageCount + outputCount))
end

local function storageSummary()
  local cache = refreshStockCache(false)
  return #P.storage, cache.usedSlots or 0, cache.totalSlots or 0
end

local function outputStock(name)
  local cache = refreshStockCache(false)
  return math.max(0, math.floor(tonumber(cache.outputTotals and cache.outputTotals[name]) or 0))
end

local function outputCapacity(name, defaultLimit)
  resolvePeripherals()
  if #P.outputs == 0 then return nil end
  local targets = P.outputs
  if not P.turtle_inventory then
    targets = {}
    for _, entry in ipairs(P.outputs) do
      if entry.name == cfg.output_side then targets[#targets + 1] = entry end
    end
    if #targets == 0 then return nil end
  end
  local capacity = 0
  for _, entry in ipairs(targets) do
    if type(entry.object.size) ~= "function" then return nil end
    local ok, size = pcall(entry.object.size)
    if not ok or type(size) ~= "number" then return nil end
    local stacks = inventoryStacks(entry.object)
    for slot = 1, size do
      local stack = stacks[slot]
      local limit = defaultLimit or 64
      if type(entry.object.getItemLimit) == "function" then
        local limitOk, itemLimit = pcall(entry.object.getItemLimit, slot)
        if limitOk and type(itemLimit) == "number" and itemLimit > 0 then limit = itemLimit end
      end
      if not stack then
        capacity = capacity + limit
      elseif stack.name == name then
        capacity = capacity + math.max(0, limit - (stack.count or 0))
      end
    end
  end
  return capacity
end

local function readHand()
  local p = resolvePeripherals()
  if p.manager and type(p.manager.getItemInHand) == "function" then
    local ok, detail = pcall(p.manager.getItemInHand)
    if ok and detail and detail.name then return detail end
  end
  -- CC:T-only fallback: select an item in Turtle slot 16.
  local detail = itemDetail(cfg.output_slot)
  if detail then return detail end
  return nil, "Inventory Managerの手持ち取得、またはTurtle slot 16のアイテムがありません。"
end

local transferMatches

local function turtleInventoryReady()
  resolvePeripherals()
  if not P.turtle_inventory_name or not P.turtle_inventory then
    return false, "Crafty Turtle自身の汎用inventory Peripheralが見つかりません。"
  end
  return true
end

local function pushTurtleSlot(slot, destination, amount)
  local ready, reason = turtleInventoryReady()
  if not ready then return false, 0, reason end
  if not destination or not destination.object or type(P.turtle_inventory.pushItems) ~= "function" then
    return false, 0, "Turtle inventoryからのpushItems()がありません。"
  end
  local beforeSource = itemDetail(slot)
  if not beforeSource or (beforeSource.count or 0) < amount then
    return false, 0, "Turtle側の転送元slotが変化しました。"
  end
  local beforeTarget = inventoryStacks(destination.object)
  local beforeCount = 0
  for _, stack in pairs(beforeTarget) do
    if stack.name == beforeSource.name then beforeCount = beforeCount + (stack.count or 0) end
  end
  local ok, moved = pcall(P.turtle_inventory.pushItems, destination.name, slot, amount)
  if not ok or type(moved) ~= "number" then
    return false, 0, tostring(moved or "pushItems()失敗")
  end
  local afterSource = itemDetail(slot)
  local afterTarget = inventoryStacks(destination.object)
  local afterCount = 0
  for _, stack in pairs(afterTarget) do
    if stack.name == beforeSource.name then afterCount = afterCount + (stack.count or 0) end
  end
  local sourceDelta = (beforeSource.count or 0) - (afterSource and afterSource.count or 0)
  if moved ~= amount or sourceDelta ~= moved or afterCount - beforeCount ~= moved then
    return false, moved, "Turtleからの転送数量検証に失敗しました。"
  end
  return true, moved
end

local function stagingReady()
  resolvePeripherals()
  if not P.staging_local_name or not P.staging then
    return false, "STAGING local side (" .. tostring(cfg.staging_side) .. ")が見つかりません。"
  end
  if not P.staging_network_name or not P.staging_network then
    return false, "STAGINGのWired Network名が解決できません。"
  end
  return true
end

local function stagingStacks()
  local ready, reason = stagingReady()
  if not ready then return nil, reason end
  local stacks, listReason = inventoryStacks(P.staging)
  if listReason then return nil, listReason end
  return stacks
end

local function stagingTotal(stacks, name)
  local total = 0
  for _, stack in pairs(stacks or {}) do
    if stack.name == name then total = total + (stack.count or 0) end
  end
  return total
end

local function stagingHasOnly(stacks, expected)
  local total = 0
  for _, stack in pairs(stacks or {}) do
    if not transferMatches(stack, expected) then return false, 0 end
    total = total + (stack.count or 0)
  end
  return true, total
end

local function stagingSlotLimit(slot)
  local limit = 64
  if P.staging and type(P.staging.getItemLimit) == "function" then
    local ok, value = pcall(P.staging.getItemLimit, slot)
    if ok and type(value) == "number" and value > 0 then limit = value end
  end
  return limit
end

local function findEmptyStagingSlot(stacks)
  if not P.staging or type(P.staging.size) ~= "function" then return nil end
  local ok, size = pcall(P.staging.size)
  if not ok or type(size) ~= "number" then return nil end
  for slot = 1, size do
    if not stacks[slot] then return slot end
  end
  return nil
end

local function transferSourceToStaging(source, sourceSlot, amount, targetSlot, expected)
  local ready, reason = stagingReady()
  if not ready then return false, 0, reason end
  if not source or not source.object or type(source.object.pushItems) ~= "function" then
    return false, 0, "素材inventory.pushItems()がありません。"
  end
  local beforeSource = inventoryStacks(source.object)[sourceSlot]
  if not transferMatches(beforeSource, expected) or (beforeSource.count or 0) < amount then
    return false, 0, "STAGING転送直前に素材inventoryのslotが変化しました。"
  end
  local beforeStaging = inventoryStacks(P.staging)[targetSlot]
  if beforeStaging then return false, 0, "STAGINGの転送先slotが空ではありません。" end
  -- pushItems() must receive the Wired Network endpoint, never "top".
  local callOk, moved = pcall(source.object.pushItems, P.staging_network_name,
    sourceSlot, amount, targetSlot)
  if not callOk or type(moved) ~= "number" then
    return false, 0, tostring(moved or "STAGING pushItems()失敗")
  end
  local afterSource = inventoryStacks(source.object)[sourceSlot]
  local afterStaging = inventoryStacks(P.staging)[targetSlot]
  local sourceDelta = (beforeSource.count or 0) - (afterSource and afterSource.count or 0)
  if moved ~= amount or sourceDelta ~= moved
    or not transferMatches(afterStaging, expected) or afterStaging.count ~= moved then
    return false, moved, "STAGINGへのItem ID/数量検証に失敗しました。"
  end
  return true, moved
end

local function suckStagingToSlot(targetSlot, amount, expected)
  local beforeStaging, reason = stagingStacks()
  if not beforeStaging then return false, reason end
  local only, beforeTotal = stagingHasOnly(beforeStaging, expected)
  if not only or beforeTotal ~= amount then
    return false, "STAGINGに異物または数量不一致があります。"
  end
  local beforeTarget = itemDetail(targetSlot)
  local beforeTargetCount = beforeTarget and beforeTarget.count or 0
  turtle.select(targetSlot)
  local ok, picked, pickReason = pcall(turtle.suckUp, amount)
  if not ok then return false, tostring(picked) end
  if picked == false then return false, tostring(pickReason or "STAGINGから吸引できません。") end
  local afterTarget = itemDetail(targetSlot)
  local afterStaging, listReason = stagingStacks()
  if not afterStaging then return false, listReason end
  local movedTarget = (afterTarget and afterTarget.count or 0) - beforeTargetCount
  local afterOnly, remaining = stagingHasOnly(afterStaging, expected)
  if movedTarget ~= amount or not transferMatches(afterTarget, expected)
    or not afterOnly or remaining ~= 0 then
    return false, ("STAGING吸引検証失敗。要求=%d target差分=%d 残置=%d"):format(
      amount, movedTarget, remaining)
  end
  local empty, slot = allNonGridEmpty(inventorySnapshot())
  if not empty then return false, "吸引後に非グリッドslotへ異物があります: " .. tostring(slot) end
  return true
end

local function dropUpToStaging(slot, amount)
  local ready, reason = stagingReady()
  if not ready then return false, reason end
  local detail = itemDetail(slot)
  if not detail or detail.count < amount then return false, "STAGING返却元slotが変化しました。" end
  local beforeStaging, listReason = stagingStacks()
  if not beforeStaging then return false, listReason end
  local beforeTotal = stagingTotal(beforeStaging, detail.name)
  local beforeCount = detail.count
  turtle.select(slot)
  local ok, moved, dropReason = pcall(turtle.dropUp, amount)
  if not ok then return false, tostring(moved) end
  if moved == false then return false, tostring(dropReason or "STAGINGが満杯です。") end
  local afterDetail = itemDetail(slot)
  local afterStaging, listReason = stagingStacks()
  if not afterStaging then return false, listReason end
  local sourceDelta = beforeCount - (afterDetail and afterDetail.count or 0)
  local stagedDelta = stagingTotal(afterStaging, detail.name) - beforeTotal
  if sourceDelta ~= amount or stagedDelta ~= amount then
    return false, "STAGING返却のItem ID/数量検証に失敗しました。"
  end
  return true
end

local function returnStagingToStorage()
  local ready, reason = stagingReady()
  if not ready then return false, reason end
  local errors = {}
  local size = 0
  if type(P.staging.size) == "function" then
    local sizeOk, value = pcall(P.staging.size)
    if sizeOk and type(value) == "number" then size = value end
  end
  for slot = 1, size do
    local stacks = stagingStacks()
    if not stacks then errors[#errors + 1] = "STAGING list()失敗" break end
    local stack = stacks[slot]
    if stack then
      local remaining = stack.count or 0
      for _, destination in ipairs(P.storage) do
        if remaining <= 0 then break end
        local beforeList, beforeReason = stagingStacks()
        if not beforeList then
          errors[#errors + 1] = beforeReason or "STAGING list()失敗"
          break
        end
        local before = beforeList[slot]
        if not before then break end
        -- Return through the Wired Network endpoint as well. The local
        -- "top" name is only for turtle.suckUp() and local inspection.
        local callOk = P.staging_network and type(P.staging_network.pushItems) == "function"
        if callOk then
          pcall(P.staging_network.pushItems, destination.name, slot, remaining)
        end
        local afterList, afterReason = stagingStacks()
        if not afterList then
          errors[#errors + 1] = afterReason or "STAGING list()失敗"
          break
        end
        local after = afterList[slot]
        local actual = (before.count or 0) - (after and after.count or 0)
        if actual > 0 then remaining = remaining - actual end
        if actual == 0 then
          -- Try another STORAGE, but never loop forever on a full destination.
        end
      end
      if remaining > 0 then
        errors[#errors + 1] = ("STAGING slot%dの返却不足: %d"):format(slot, remaining)
      end
    end
  end
  return #errors == 0, table.concat(errors, "; ")
end

local function dropSlotDown(slot, amount)
  turtle.select(slot)
  local ok, moved, reason = pcall(turtle.dropDown, amount)
  if not ok then return false, tostring(moved) end
  if moved == false then return false, tostring(reason or "下側output chestが満杯です。") end
  if itemDetail(slot) then return false, "下側output chestへの排出後もTurtleに残っています。" end
  return true
end

local function returnTurtleSlot(slot, amount, preferred)
  resolvePeripherals()
  if not P.turtle_inventory then
    return dropUpToStaging(slot, amount)
  end
  local destinations = {}
  if preferred then destinations[#destinations + 1] = preferred end
  for _, entry in ipairs(P.storage) do
    if not preferred or entry.name ~= preferred.name then destinations[#destinations + 1] = entry end
  end
  local detail = itemDetail(slot)
  if not detail then return true end
  local remaining = math.min(amount or detail.count, detail.count)
  for _, destination in ipairs(destinations) do
    if remaining <= 0 then break end
    local ok, moved = pushTurtleSlot(slot, destination, remaining)
    if ok and moved > 0 then remaining = remaining - moved end
  end
  if remaining > 0 then return false, ("slot%dの返却不足: %d"):format(slot, remaining) end
  return true
end

local function returnAllToStorage()
  resolvePeripherals()
  local errors = {}
  for slot = 1, 16 do
    local detail = itemDetail(slot)
    if detail then
      local ok, reason = returnTurtleSlot(slot, detail.count)
      if not ok then errors[#errors + 1] = ("slot%d: %s"):format(slot, tostring(reason)) end
    end
  end
  if not P.turtle_inventory then
    local returned, reason = returnStagingToStorage()
    if not returned then errors[#errors + 1] = "STAGING: " .. tostring(reason) end
  end
  return #errors == 0, table.concat(errors, "; ")
end

local function outputDestination(name)
  resolvePeripherals()
  for _, entry in ipairs(P.outputs) do
    local stacks = inventoryStacks(entry.object)
    local size = 0
    if type(entry.object.size) == "function" then
      local sizeOk, value = pcall(entry.object.size)
      if sizeOk and type(value) == "number" then size = value end
    end
    for slot = 1, size do
      local stack = stacks[slot]
      local limit = 64
      if type(entry.object.getItemLimit) == "function" then
        local ok, value = pcall(entry.object.getItemLimit, slot)
        if ok and type(value) == "number" and value > 0 then limit = value end
      end
      if not stack or (stack.name == name and (stack.count or 0) < limit) then
        return entry
      end
    end
  end
  return P.outputs[1]
end

local function pushOutputOrDrop(slot, name, amount)
  local output = outputDestination(name)
  if output and P.turtle_inventory then
    local ok, moved = pushTurtleSlot(slot, output, amount)
    if ok and moved == amount then return true end
    if moved and moved > 0 then
      return false, ("完成品の部分転送: %d/%d"):format(moved, amount)
    end
  end
  -- The lower chest/barrel may be invisible to the peripheral API. Use the
  -- turtle API as the real fallback instead of gating it on isPresent().
  if cfg.output_side then
    local dropped, dropReason = dropSlotDown(slot, amount)
    if dropped then return true end
    return false, dropReason or "下側output chestへの排出に失敗しました。"
  end
  return false, "OUTPUT inventoryも下側output chestもありません。"
end

local function prepareEmptyInventory()
  local snapshot = inventorySnapshot()
  local empty, slot = allTurtleEmpty(snapshot)
  if not empty then
    return false, "Turtle inventoryが空ではありません。slot " .. slot .. "を確認してください。"
  end
  return true
end

local function craftObject()
  local p = resolvePeripherals()
  if p.craft then return p.craft end
  return turtle
end

local function callCraft(amount)
  local object = craftObject()
  if type(object.craft) ~= "function" then return false, "craft()がありません。" end
  local ok, result, reason = pcall(object.craft, amount)
  if not ok then return false, tostring(result) end
  if result == false then return false, tostring(reason or "No matching recipe") end
  return true, result
end

local function captureGrid()
  local grid = gridSnapshot()
  if not hasIngredient(grid) then return nil, "3x3 gridに材料がありません。" end
  return grid
end

local function findCraftOutput(after, expectedName)
  local candidates = {}
  for _, slot in ipairs(NON_GRID_SLOTS) do
    local detail = after[slot]
    if detail and detail ~= "" then
      if expectedName and detail.name == expectedName then
        candidates[#candidates + 1] = { slot = slot, detail = detail }
      elseif not expectedName and slot == cfg.output_slot then
        candidates[#candidates + 1] = { slot = slot, detail = detail }
      end
    end
  end
  return candidates
end

local function cleanupCraftResult(outputName)
  local after = inventorySnapshot()
  local outputSlots = findCraftOutput(after, outputName)
  local outputCount = 0
  local warnings = {}

  for _, result in ipairs(outputSlots) do
    outputCount = outputCount + (result.detail.count or 0)
  end

  for _, slot in ipairs(NON_GRID_SLOTS) do
    local detail = after[slot]
    if detail and detail ~= "" then
      local isOutput = false
      for _, result in ipairs(outputSlots) do
        if result.slot == slot then isOutput = true break end
      end
      if isOutput then
        local ok, reason = pushOutputOrDrop(slot, outputName, detail.count)
        if not ok then warnings[#warnings + 1] = reason or "完成品排出失敗" end
      else
        local ok, reason = returnTurtleSlot(slot, detail.count)
        if not ok then warnings[#warnings + 1] = reason or "残り物返却失敗" end
      end
    end
  end

  -- Recipe remainders stay in the grid. Return them to the input Barrel;
  -- never drop unknown grid contents into the finished-product output.
  for _, slot in ipairs(CRAFT_SLOTS) do
    local detail = itemDetail(slot)
    if detail then
      local ok, reason = returnTurtleSlot(slot, detail.count)
      if not ok then warnings[#warnings + 1] = reason or "レシピ残り物返却失敗" end
    end
  end

  if not P.turtle_inventory then
    local returned, reason = returnStagingToStorage()
    if not returned then warnings[#warnings + 1] = reason or "STAGINGからの返却失敗" end
  end

  return outputCount, table.concat(warnings, "; ")
end

local function testAndRegister()
  local snapshot = inventorySnapshot()
  local empty, slot = allNonGridEmpty(snapshot)
  if not empty then
    return false, "テスト前に非グリッドslot " .. slot .. "を空にしてください。"
  end
  local grid, reason = captureGrid()
  if not grid then return false, reason end

  turtle.select(cfg.output_slot)
  local ok, result = callCraft(1)
  if not ok then
    return false, "No matching recipe: " .. tostring(result)
  end

  local after = inventorySnapshot()
  local candidates = findCraftOutput(after, nil)
  if #candidates == 0 then
    local returned, returnReason = returnAllToStorage()
    return false, "クラフト成功後の出力を検出できませんでした。"
      .. (returned and "" or " " .. returnReason)
  end

  local output = copy(candidates[1].detail)
  local outputCount, warning = cleanupCraftResult(output.name)
  if outputCount <= 0 then
    return false, "完成品を下側Barrelへ排出できませんでした。" .. tostring(warning or "")
  end
  if warning and warning ~= "" then
    return false, "テスト結果の排出・残り物処理に失敗したため登録しません。" .. warning
  end

  local recipes = loadRecipes()
  local recipe = {
    name = uniqueRecipeName(recipes, output),
    output = {
      name = output.name,
      displayName = output.displayName or output.name,
      count = outputCount,
      maxCount = output.maxCount,
    },
    grid = grid,
    target = cfg.target_stock,
    captured_at = now(),
  }
  recipes[recipe.name] = recipe
  saveRecipes(recipes)
  state.selected = recipe
  state.preview = grid
  state.message = "REGISTERED: " .. recipe.name
  return true, recipe
end

local function batchLimit(recipe, requested, cache)
  local batch = math.max(1, math.min(math.floor(tonumber(requested) or 1), cfg.batch_limit))
  cache = cache or refreshStockCache(false)
  local needed = {}
  for _, entry in ipairs(gridIngredients(recipe)) do
    needed[entry.item] = (needed[entry.item] or 0) + entry.count
    local stackLimit = entry.detail and entry.detail.maxCount or 64
    batch = math.min(batch, math.floor(stackLimit / entry.count))
  end
  for name, perCraft in pairs(needed) do
    local available = stockCount(name, cache)
    batch = math.min(batch, math.floor(available / perCraft))
  end
  local output = recipeOutput(recipe)
  local outputCount = output and output.count or 1
  local outputMax = output and output.maxCount or 64
  if outputCount > 0 then
    batch = math.min(batch, math.floor((#NON_GRID_SLOTS * outputMax) / outputCount))
    cache.outputCapacities = cache.outputCapacities or {}
    local outputKey = output.name .. ":" .. tostring(outputMax)
    if cache.outputCapacities[outputKey] == nil then
      cache.outputCapacities[outputKey] = outputCapacity(output.name, outputMax)
    end
    local availableOutput = cache.outputCapacities[outputKey]
    if availableOutput ~= nil then
      batch = math.min(batch, math.floor(availableOutput / outputCount))
    end
  end
  return math.max(0, batch)
end

transferMatches = function(detail, expected)
  if not detail or not expected or detail.name ~= expected.item then return false end
  if expected.detail and expected.detail.nbt and detail.nbt
    and expected.detail.nbt ~= detail.nbt then
    return false
  end
  return true
end

local function transferFromSource(source, sourceSlot, amount, targetSlot, expected)
  local ready, reason = turtleInventoryReady()
  if not ready then return false, 0, reason end
  if not source or not source.object or type(source.object.pushItems) ~= "function" then
    return false, 0, "素材inventory.pushItems()がありません。"
  end
  local beforeSource = inventoryStacks(source.object)[sourceSlot]
  if not transferMatches(beforeSource, expected) or (beforeSource.count or 0) < amount then
    return false, 0, "転送直前に素材inventoryのslotが変化しました。"
  end
  local before = itemDetail(targetSlot)
  local ok, moved = pcall(source.object.pushItems, P.turtle_inventory_name,
    sourceSlot, amount, targetSlot)
  if not ok or type(moved) ~= "number" then
    return false, 0, tostring(moved or "pushItems()失敗")
  end
  local after = itemDetail(targetSlot)
  local afterSource = inventoryStacks(source.object)[sourceSlot]
  local beforeCount = before and before.count or 0
  local afterCount = after and after.count or 0
  local observedTarget = afterCount - beforeCount
  local observedSource = (beforeSource.count or 0) - (afterSource and afterSource.count or 0)
  if moved ~= amount or observedTarget ~= moved or observedSource ~= moved then
    return false, moved, ("転送数量検証失敗。要求=%d 実転送=%d target差分=%d source差分=%d"):format(
      amount, moved, observedTarget, observedSource)
  end
  if not transferMatches(after, expected) then
    return false, moved, "転送後のcraft slotに異なるItem ID/NBTがあります。"
  end
  return true, moved
end

local function returnTransferRecords(records)
  local errors = {}
  for index = #records, 1, -1 do
    local record = records[index]
    if itemDetail(record.targetSlot) then
      local ok, moved, reason
      if record.source.object and type(record.source.object.pullItems) == "function" then
        local callOk, result = pcall(record.source.object.pullItems,
          P.turtle_inventory_name, record.targetSlot, record.amount, record.sourceSlot)
        ok, moved = callOk and type(result) == "number", result
        if not callOk then reason = tostring(result) end
      else
        ok, moved, reason = pushTurtleSlot(record.targetSlot, record.source, record.amount)
      end
      if not ok or moved ~= record.amount then
        errors[#errors + 1] = reason or ("slot%dから%sへ%d個返却できません"):format(
          record.targetSlot, record.source.name, record.amount)
      end
    end
  end
  return #errors == 0, table.concat(errors, "; ")
end

local function transferMaterialsToGrid(recipe, batch, cache)
  local ready, reason = turtleInventoryReady()
  if not ready then return false, nil, reason end
  local records = {}
  local reservations = {}

  for _, entry in ipairs(gridIngredients(recipe)) do
    local remaining = entry.count * batch
    while remaining > 0 do
      local selectedSource, selectedSlot, selectedCount
      for _, source in ipairs(P.storage) do
        local indexed = cache.inventories[source.name]
        if indexed and indexed.stacks then
          for slot, candidate in pairs(indexed.stacks) do
            local reserved = reservations[source.name] and reservations[source.name][slot] or 0
            local candidateExpected = { item = entry.item, detail = entry.detail }
            if candidate and transferMatches(candidate, candidateExpected) and not selectedSource
              and (candidate.count or 0) - reserved > 0 then
              selectedSource, selectedSlot = source, slot
              selectedCount = math.min(remaining, (candidate.count or 0) - reserved)
              break
            end
          end
        end
        if selectedSource then break end
      end
      if not selectedSource then
        local returned, returnReason = returnTransferRecords(records)
        local message = "統合倉庫の再確認後、素材が不足しました: " .. entry.item
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, records, message
      end

      local expected = { item = entry.item, detail = entry.detail }
      local ok, moved, transferReason = transferFromSource(
        selectedSource, selectedSlot, selectedCount, entry.physical, expected)
      if not ok then
        if moved and moved > 0 then
          records[#records + 1] = {
            source = selectedSource,
            sourceSlot = selectedSlot,
            targetSlot = entry.physical,
            amount = moved,
          }
        end
        local returned, returnReason = returnTransferRecords(records)
        local message = transferReason or ("素材転送失敗: " .. entry.item)
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, records, message
      end
      reservations[selectedSource.name] = reservations[selectedSource.name] or {}
      reservations[selectedSource.name][selectedSlot] =
        (reservations[selectedSource.name][selectedSlot] or 0) + moved
      records[#records + 1] = {
        source = selectedSource,
        sourceSlot = selectedSlot,
        targetSlot = entry.physical,
        amount = moved,
      }
      remaining = remaining - moved
    end
  end

  local snapshot = inventorySnapshot()
  local empty, emptySlot = allNonGridEmpty(snapshot)
  if not empty then
    local returned, returnReason = returnTransferRecords(records)
    local message = "転送後に非グリッドslotへ異物があります: " .. tostring(emptySlot)
    if not returned then message = message .. " / 返却: " .. returnReason end
    return false, records, message
  end
  for _, entry in ipairs(gridIngredients(recipe)) do
    local detail = snapshot[entry.physical]
    local expectedCount = entry.count * batch
    if not transferMatches(detail, entry) or detail.count ~= expectedCount then
      local returned, returnReason = returnTransferRecords(records)
      local message = ("craft slot %dの検証失敗: %s x%d"):format(
        entry.physical, entry.item, expectedCount)
      if not returned then message = message .. " / 返却: " .. returnReason end
      return false, records, message
    end
  end
  return true, records
end

local function transferMaterialsViaStaging(recipe, batch, cache)
  local ready, reason = stagingReady()
  if not ready then return false, reason end
  local initial, listReason = stagingStacks()
  if not initial then return false, listReason end
  if next(initial) ~= nil then
    return false, "STAGINGが空ではありません。残留物を確認してください。"
  end

  local reservations = {}
  for _, entry in ipairs(gridIngredients(recipe)) do
    local remaining = entry.count * batch
    local expected = { item = entry.item, detail = entry.detail }
    while remaining > 0 do
      local selectedSource, selectedSlot, selectedCount
      for _, source in ipairs(P.storage) do
        local indexed = cache.inventories[source.name]
        if indexed and indexed.stacks then
          for slot, candidate in pairs(indexed.stacks) do
            local reserved = reservations[source.name] and reservations[source.name][slot] or 0
            if candidate and transferMatches(candidate, expected) and not selectedSource
              and (candidate.count or 0) - reserved > 0 then
              selectedSource, selectedSlot = source, slot
              selectedCount = (candidate.count or 0) - reserved
              break
            end
          end
        end
        if selectedSource then break end
      end
      if not selectedSource then
        local returned, returnReason = returnAllToStorage()
        local message = "STAGING投入前に素材が不足しました: " .. entry.item
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, message
      end

      local current, currentReason = stagingStacks()
      if not current then return false, currentReason end
      if next(current) ~= nil then
        local returned, returnReason = returnAllToStorage()
        local message = "STAGINGに予期しない残留物があります。"
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, message
      end
      local targetSlot = findEmptyStagingSlot(current)
      if not targetSlot then
        return false, "STAGINGに空きslotがありません。"
      end
      local amount = math.min(remaining, selectedCount, stagingSlotLimit(targetSlot))
      local transferred, moved, transferReason = transferSourceToStaging(
        selectedSource, selectedSlot, amount, targetSlot, expected)
      if not transferred then
        local returned, returnReason = returnAllToStorage()
        local message = transferReason or "STAGINGへの材料転送に失敗しました。"
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, message
      end

      local staged = stagingStacks()
      local only, total = stagingHasOnly(staged, expected)
      if not only or total ~= moved then
        local returned, returnReason = returnAllToStorage()
        local message = "STAGING投入後のItem ID/数量検証に失敗しました。"
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, message
      end

      local picked, pickReason = suckStagingToSlot(entry.physical, moved, expected)
      if not picked then
        local returned, returnReason = returnAllToStorage()
        local message = pickReason or "STAGINGからの吸引に失敗しました。"
        if not returned then message = message .. " / 返却: " .. returnReason end
        return false, message
      end
      reservations[selectedSource.name] = reservations[selectedSource.name] or {}
      reservations[selectedSource.name][selectedSlot] =
        (reservations[selectedSource.name][selectedSlot] or 0) + moved
      remaining = remaining - moved
    end
  end

  local snapshot = inventorySnapshot()
  local empty, emptySlot = allNonGridEmpty(snapshot)
  if not empty then
    local returned, returnReason = returnAllToStorage()
    local message = "STAGING吸引後に非グリッドslotへ異物があります: " .. tostring(emptySlot)
    if not returned then message = message .. " / 返却: " .. returnReason end
    return false, message
  end
  for _, entry in ipairs(gridIngredients(recipe)) do
    local detail = snapshot[entry.physical]
    local expectedCount = entry.count * batch
    if not transferMatches(detail, entry) or detail.count ~= expectedCount then
      local returned, returnReason = returnAllToStorage()
      local message = ("STAGING後のcraft slot検証失敗: slot%d %s x%d"):format(
        entry.physical, entry.item, expectedCount)
      if not returned then message = message .. " / 返却: " .. returnReason end
      return false, message
    end
  end
  return true
end

local function craftBatch(recipe, requested)
  local empty, reason = prepareEmptyInventory()
  if not empty then return false, 0, 0, reason end
  local cache = refreshStockCache(false)
  local batch = batchLimit(recipe, requested, cache)
  if batch <= 0 then
    return false, 0, 0, "材料不足、または安全なbatch sizeが0です。"
  end

  resolvePeripherals()
  local ok, records, fillReason
  if P.turtle_inventory then
    ok, records, fillReason = transferMaterialsToGrid(recipe, batch, cache)
  else
    ok, fillReason = transferMaterialsViaStaging(recipe, batch, cache)
  end
  if not ok then
    return false, 0, 0, fillReason
  end

  turtle.select(cfg.output_slot)
  local crafted, result = callCraft(batch)
  if not crafted then
    local returned, returnReason
    if P.turtle_inventory then
      returned, returnReason = returnTransferRecords(records)
    else
      returned, returnReason = returnAllToStorage()
    end
    if not returned then result = tostring(result) .. " / 素材返却: " .. returnReason end
    return false, 0, 0, tostring(result)
  end

  local outputCount, warning = cleanupCraftResult(recipe.output.name)
  local message = warning
  if outputCount == 0 then
    message = (message ~= "" and message .. " / " or "") .. "完成品を検出できませんでした。Turtle内を確認してください。"
  end
  -- Once craft() succeeded, consume this queue job even if output detection
  -- was imperfect. Otherwise retrying could duplicate production.
  return true, batch, outputCount, message
end

local function loadQueue()
  local raw = readTable(cfg.queue_file, {})
  if type(raw) ~= "table" then return {} end
  return raw
end

local function saveQueue(queue)
  writeAtomic(cfg.queue_file, queue)
end

local function queueAdd(recipe, amount, isAuto)
  local queue = loadQueue()
  queue[#queue + 1] = {
    recipe = copy(recipe),
    amount = math.max(1, math.floor(tonumber(amount) or 1)),
    auto = isAuto == true,
    added = now(),
  }
  saveQueue(queue)
  return queue
end

local function targetPlan(recipe, cache)
  cache = cache or refreshStockCache(false)
  local target = math.max(0, math.floor(tonumber(recipe.target) or cfg.target_stock))
  local current = finishedStockCount(recipe.output.name, cache)
  local missing = math.max(0, target - current)
  local outputPerCraft = math.max(1, math.floor(tonumber(recipe.output.count) or 1))
  local requestedCrafts = math.ceil(missing / outputPerCraft)
  return target, current, missing, requestedCrafts
end

local function queueAuto(recipe)
  local target, current, missing, amount = targetPlan(recipe)
  if missing <= 0 then return false, "完成品在庫 " .. current .. "/" .. target .. "で生産不要です。" end
  amount = math.min(cfg.batch_limit, amount)
  if amount <= 0 then return false, "Targetまでの必要craft数が0です。" end
  queueAdd(recipe, amount, false)
  return true, ("AUTOをキューへ追加: %s x%d (stock=%d/%d)"):format(
    recipe.name, amount, current, target)
end

-- Add at most one automatic job per scan. This makes competing recipes
-- deterministic: the next scan observes the reduced inventory before another
-- recipe is selected. Manual queue jobs always take priority.
local function planAutoJob()
  if not autoState.global or autoState.blocked then
    state.auto_current = nil
    return false
  end
  local queue = loadQueue()
  if #queue > 0 then return false end

  local recipes = loadRecipes()
  local keys = recipeKeys(recipes)
  if #keys == 0 then
    state.auto_current = nil
    return false
  end
  local cache = refreshStockCache(false)
  local start = 1
  if autoState.cursor then
    for index, name in ipairs(keys) do
      if name == autoState.cursor then
        start = (index % #keys) + 1
        break
      end
    end
  end
  for offset = 0, #keys - 1 do
    local name = keys[((start + offset - 1) % #keys) + 1]
    if recipeAutoEnabled(name) then
      local recipe = normalizeRecipe(recipes[name])
      if recipe then
        local target, current, missing, requestedCrafts = targetPlan(recipe, cache)
        if missing > 0 then
          local batch = batchLimit(recipe, requestedCrafts, cache)
          if batch > 0 then
            queueAdd(recipe, batch, true)
            state.auto_current = recipe.name
            autoState.cursor = name
            saveAuto()
            state.queue_job = loadQueue()[1]
            return true
          end
        end
      end
    end
  end
  state.auto_current = nil
  return false
end

local function processQueueOnce()
  local queue = loadQueue()
  local job = queue[1]
  state.queue_job = job
  if not job then return false end
  if job.auto and (not autoState.global or autoState.blocked) then
    state.auto_current = nil
    return false
  end
  local recipe = normalizeRecipe(job.recipe)
  if not recipe then
    table.remove(queue, 1)
    saveQueue(queue)
    setMessage("不正なqueue jobを削除しました。", true)
    return true
  end
  local isAuto = job.auto == true or state.auto_current == recipe.name
  if isAuto then state.auto_current = recipe.name end
  local ok, completed, produced, warning = craftBatch(recipe, job.amount)
  if not ok then
    if isAuto then
      autoState.blocked = true
      state.auto_blocked = true
      state.auto_current = nil
      saveAuto()
    end
    setMessage("停止: " .. tostring(warning), true)
    sleep(3)
    return false
  end
  job.amount = job.amount - math.max(1, completed)
  if job.amount <= 0 then table.remove(queue, 1) end
  saveQueue(queue)
  if isAuto and warning and warning ~= "" then
    autoState.blocked = true
    state.auto_blocked = true
    state.auto_current = nil
    saveAuto()
  elseif isAuto and job.amount <= 0 then
    state.auto_current = nil
  end
  local text = ("完了: %s craft=%d output=%d"):format(recipe.name, completed, produced)
  if warning and warning ~= "" then text = text .. " / " .. warning end
  setMessage(text, warning ~= nil and warning ~= "")
  state.queue_job = queue[1]
  return true
end

local function queueLoop()
  while true do
    local ok, reason = pcall(processQueueOnce)
    if not ok then
      setMessage("queue runtime error: " .. tostring(reason), true)
      resetPeripherals()
      sleep(3)
    elseif not reason then
      local planned, planReason = pcall(planAutoJob)
      if not planned then
        setMessage("AUTO planner error: " .. tostring(planReason), true)
        resetPeripherals()
      end
      sleep(cfg.auto_poll_seconds)
    end
  end
end

local function toggleGlobalAuto()
  autoState.global = not autoState.global
  -- Turning AUTO back on is an explicit recovery action after a full barrel,
  -- craft failure, or output handling warning.
  if autoState.global then autoState.blocked = false end
  state.auto_global = autoState.global
  state.auto_blocked = autoState.blocked
  saveAuto()
  setMessage("AUTO " .. (autoState.global and "ON" or "OFF"), false)
end

local function toggleRecipeAuto(recipe)
  if not recipe then return end
  autoState.recipes[recipe.name] = not recipeAutoEnabled(recipe.name)
  saveAuto()
  setMessage(("%s AUTO %s"):format(recipe.name, recipeAutoEnabled(recipe.name) and "ON" or "OFF"), false)
end

local function setColour(display, foreground, background)
  if display.setTextColor then display.setTextColor(foreground) end
  if display.setTextColour then display.setTextColour(foreground) end
  if display.setBackgroundColor then display.setBackgroundColor(background or colors.black) end
  if display.setBackgroundColour then display.setBackgroundColour(background or colors.black) end
end

-- Monitor dimensions are measured after changing the text scale.  A 3x3
-- Advanced Monitor is often smaller than the old fixed 40x16 layout, so all
-- drawing and hitboxes use this same measured coordinate system.
local MONITOR_SCALES = { 1.0, 0.75, 0.5 }
local monitorLayout = {
  display = nil,
  width = 0,
  height = 0,
  scale = 0.5,
  compact = true,
}

-- Tom's GPU accepts ARGB colours, while CC:T colours are bit flags.  Keep
-- this conversion local to the optional GPU surface so the normal Monitor
-- path remains unchanged.
local GPU_COLOURS = {
  [colors.black] = 0xFF000000,
  [colors.white] = 0xFFFFFFFF,
  [colors.red] = 0xFFFF5555,
  [colors.green] = 0xFF55FF55,
  [colors.blue] = 0xFF5555FF,
  [colors.yellow] = 0xFFFFFF55,
  [colors.orange] = 0xFFFFAA00,
  [colors.lightBlue] = 0xFF55FFFF,
  [colors.lightGray] = 0xFFAAAAAA,
  [colors.gray] = 0xFF555555,
  [colors.pink] = 0xFFFF55FF,
  [colors.purple] = 0xFFAA00AA,
}

local function gpuColour(colour)
  return GPU_COLOURS[colour] or GPU_COLOURS[colors.white]
end

-- A small terminal-compatible adapter.  Existing GUI functions continue to
-- operate in character cells, while Tom's GPU draws the same frame into its
-- VRAM and sends it once with sync(). This avoids hundreds of network writes
-- to an Advanced Monitor on each refresh.
local function newGpuDisplay(rootGpu)
  -- On NeoForge 1.21.1, Tom's GPU examples use a child window for drawing.
  -- Keep the root GPU for the final sync, but issue all draw calls to the
  -- window context. A zero-tick yield lets refreshSize/setSize finish before
  -- the window queries the connected Bitmap Monitor dimensions.
  rootGpu.refreshSize()
  if type(sleep) == "function" then sleep(0) end
  if type(rootGpu.setSize) == "function" and cfg.gpu_resolution then
    local resized, resizeReason = pcall(rootGpu.setSize, cfg.gpu_resolution)
    if resized then
      if type(sleep) == "function" then sleep(0) end
    else
      log("WARN", "Tom's GPU setSize skipped: " .. tostring(resizeReason))
    end
  end
  local sizeOk, rootWidth, rootHeight = pcall(rootGpu.getSize)
  if not sizeOk or type(rootWidth) ~= "number" or type(rootHeight) ~= "number" then
    error("Tom's GPU getSize() failed", 0)
  end
  local gpu = rootGpu
  if type(rootGpu.createWindow) == "function" then
    local windowOk, window = pcall(rootGpu.createWindow, 1, 1, rootWidth, rootHeight)
    if not windowOk or window == nil then
      error("Tom's GPU createWindow() failed: " .. tostring(window), 0)
    end
    gpu = window
  end
  if type(gpu.filledRectangle) ~= "function" or type(gpu.drawText) ~= "function" then
    error("Tom's GPU drawing methods are unavailable", 0)
  end

  local surface = {
    gpu = gpu,
    root_gpu = rootGpu,
    width = 1,
    height = 1,
    pixel_width = 1,
    pixel_height = 1,
    text_scale = 1,
    cell_width = 6,
    cell_height = 9,
    cursor_x = 1,
    cursor_y = 1,
    foreground = colors.white,
    background = colors.black,
  }

  local function refreshMetrics()
    local ok, pixelWidth, pixelHeight = pcall(gpu.getSize)
    if not ok or type(pixelWidth) ~= "number" or type(pixelHeight) ~= "number" then
      error("Tom's GPU getSize() failed", 0)
    end
    surface.pixel_width = math.max(1, math.floor(pixelWidth))
    surface.pixel_height = math.max(1, math.floor(pixelHeight))
    -- Tom's terminal emulator uses 6x9 pixels per character at scale 1.
    -- Use the same metrics so drawText and tm_monitor_touch agree.
    surface.cell_width = math.max(1, math.floor(6 * surface.text_scale + 0.5))
    surface.cell_height = math.max(1, math.floor(9 * surface.text_scale + 0.5))
    surface.width = math.max(1, math.floor(surface.pixel_width / surface.cell_width))
    surface.height = math.max(1, math.floor(surface.pixel_height / surface.cell_height))
  end

  function surface.getSize()
    refreshMetrics()
    return surface.width, surface.height
  end

  function surface.setTextScale(scale)
    if type(scale) ~= "number" or scale <= 0 then error("invalid GPU text scale", 0) end
    surface.text_scale = scale
    refreshMetrics()
  end

  function surface.setCursorPos(x, y)
    surface.cursor_x = math.max(1, math.floor(tonumber(x) or 1))
    surface.cursor_y = math.max(1, math.floor(tonumber(y) or 1))
  end

  function surface.setTextColor(colour) surface.foreground = colour end
  function surface.setTextColour(colour) surface.foreground = colour end
  function surface.setBackgroundColor(colour) surface.background = colour end
  function surface.setBackgroundColour(colour) surface.background = colour end

  function surface.clear()
    if type(gpu.fill) == "function" then
      gpu.fill(gpuColour(surface.background))
    else
      gpu.filledRectangle(1, 1, surface.pixel_width, surface.pixel_height, gpuColour(surface.background))
    end
    surface.cursor_x, surface.cursor_y = 1, 1
  end

  function surface.write(text)
    text = tostring(text or "")
    if text == "" then return end
    local pixelX = (surface.cursor_x - 1) * surface.cell_width + 1
    local pixelY = (surface.cursor_y - 1) * surface.cell_height + 1
    local pixelWidth = math.min(
      surface.pixel_width - pixelX + 1,
      math.max(1, math.floor(#text * surface.cell_width))
    )
    if pixelX <= surface.pixel_width and pixelY <= surface.pixel_height then
      gpu.filledRectangle(pixelX, pixelY, pixelWidth, surface.cell_height, gpuColour(surface.background))
      gpu.drawText(pixelX, pixelY, text, gpuColour(surface.foreground),
        -1, surface.text_scale, 0)
    end
  end

  function surface.pixelToCell(x, y)
    return math.floor((tonumber(x) or 1) / surface.cell_width) + 1,
      math.floor((tonumber(y) or 1) / surface.cell_height) + 1
  end

  function surface.sync()
    if gpu ~= rootGpu and type(gpu.sync) == "function" then gpu.sync() end
    rootGpu.sync()
  end

  refreshMetrics()
  return surface
end

local function monitorSize(display)
  local ok, width, height = pcall(display.getSize)
  if not ok or type(width) ~= "number" or type(height) ~= "number" then
    return 1, 1
  end
  return math.max(1, math.floor(width)), math.max(1, math.floor(height))
end

local function configureMonitor(display)
  -- Read the initial size as soon as the monitor is connected.  This also
  -- supports monitor implementations which do not expose a useful size until
  -- getSize() has been called once.
  local initialWidth, initialHeight = monitorSize(display)
  local selectedScale = 0.5
  local selectedWidth, selectedHeight = initialWidth, initialHeight

  -- Prefer the largest readable scale which still fits the responsive HOME
  -- layout.  If a 3x3 monitor cannot reach that size, 0.5 is the most useful
  -- fallback because it provides the most character cells.
  for _, scale in ipairs(MONITOR_SCALES) do
    local scaleOk = pcall(display.setTextScale, scale)
    if scaleOk then
      local width, height = monitorSize(display)
      selectedScale, selectedWidth, selectedHeight = scale, width, height
      if width >= 28 and height >= 16 then break end
    end
  end

  pcall(display.setTextScale, selectedScale)
  selectedWidth, selectedHeight = monitorSize(display)
  monitorLayout.display = display
  monitorLayout.width = selectedWidth
  monitorLayout.height = selectedHeight
  monitorLayout.scale = selectedScale
  monitorLayout.compact = selectedWidth < 28 or selectedHeight < 16
  state.monitor_size = ("%dx%d scale=%.2f"):format(selectedWidth, selectedHeight, selectedScale)
end

local function ensureMonitorLayout(display)
  -- Re-measuring and changing text scale during every draw can clear an
  -- Advanced Monitor while its wired-network update is still in flight. The
  -- layout is selected once when the peripheral is connected; a peripheral
  -- reconnect/refresh deliberately selects it again.
  if monitorLayout.display ~= display or monitorLayout.width < 1 or monitorLayout.height < 1 then
    configureMonitor(display)
  end
  return monitorLayout.width, monitorLayout.height
end

-- CC:T monitors support blit(), which sends one text/colour run instead of
-- making separate colour and write calls for every line.  Keep a write()
-- fallback for GPU surfaces and for UTF-8 text: blit() uses one colour code
-- per rendered character, while Lua's # operator counts UTF-8 bytes.
local function writeDisplayText(display, text, foreground, background)
  text = tostring(text or "")
  if text == "" then return end

  local ascii = true
  for index = 1, #text do
    if text:byte(index) > 127 then
      ascii = false
      break
    end
  end

  if ascii and type(display.blit) == "function" and type(colors.toBlit) == "function" then
    local foregroundCode = colors.toBlit(foreground or colors.white)
    local backgroundCode = colors.toBlit(background or colors.black)
    display.blit(text, string.rep(foregroundCode, #text), string.rep(backgroundCode, #text))
  else
    setColour(display, foreground or colors.white, background or colors.black)
    display.write(text)
  end
end

local function line(display, y, text, colour)
  local width, height = ensureMonitorLayout(display)
  if y < 1 or y > height then return end
  display.setCursorPos(1, y)
  writeDisplayText(display, tostring(text or ""):sub(1, width), colour, colors.black)
end

local function lineAt(display, x, y, text, colour)
  local screenWidth, height = ensureMonitorLayout(display)
  x = math.max(1, math.floor(tonumber(x) or 1))
  if y < 1 or y > height or x > screenWidth then return end
  local maxLength = screenWidth - x + 1
  display.setCursorPos(x, y)
  writeDisplayText(display, tostring(text or ""):sub(1, maxLength), colour, colors.black)
end

local function button(display, x, y, width, label, action)
  local screenWidth, height = ensureMonitorLayout(display)
  if y < 1 or y > height or x > screenWidth then return end
  width = math.max(1, math.floor(tonumber(width) or 1))
  width = math.min(width, math.max(1, screenWidth - x - 1))
  local labelText = tostring(label or "")
  if #labelText > width then labelText = labelText:sub(1, width) end
  local text = "[" .. labelText .. string.rep(" ", width - #labelText) .. "]"
  local visibleText = text:sub(1, math.max(1, screenWidth - x + 1))
  lineAt(display, x, y, visibleText)
  state.buttons[#state.buttons + 1] = {
    x1 = x, y1 = y, x2 = x + #visibleText - 1, y2 = y, action = action,
  }
end

local function buttonGrid(display, y, items, columns)
  local screenWidth, screenHeight = ensureMonitorLayout(display)
  columns = math.max(1, math.min(columns or 2, #items))
  local gap = 1
  local cellWidth = math.floor((screenWidth - gap * (columns - 1)) / columns)
  if cellWidth < 5 and columns > 1 then
    columns = 1
    cellWidth = screenWidth
  end
  local contentWidth = math.max(1, cellWidth - 2)
  for index, item in ipairs(items) do
    local row = math.floor((index - 1) / columns)
    local column = (index - 1) % columns
    local x = 1 + column * (cellWidth + gap)
    local targetY = y + row
    if targetY <= screenHeight then
      button(display, x, targetY, contentWidth, item.label, item.action)
    end
  end
  return math.ceil(#items / columns)
end

local function drawGrid(display, grid, top)
  local screenWidth = ensureMonitorLayout(display)
  local cellWidth = math.max(1, math.floor((screenWidth - 2) / 3))
  for row = 1, 3 do
    local cells = {}
    for column = 1, 3 do
      local logical = (row - 1) * 3 + column
      local entry = grid and grid[logical] or ""
      local text = type(entry) == "table" and (entry.displayName or entry.name) or entry
      local cell = shortName(text, math.max(1, cellWidth - 1))
      cells[#cells + 1] = cell .. string.rep(" ", math.max(0, cellWidth - #cell))
    end
    lineAt(display, 1, top + row - 1, table.concat(cells, "|"), colors.lightBlue)
  end
end

local function drawHeader(display, text)
  ensureMonitorLayout(display)
  display.setBackgroundColor(colors.black)
  display.clear()
  state.buttons = {}
  line(display, 1, text, colors.yellow)
end

local function drawHome(display)
  drawHeader(display, "FACTORY")
  local recipes = loadRecipes()
  local storageCount, usedSlots, totalSlots = storageSummary()
  local autoStatus = autoState.global and "ON" or "OFF"
  if autoState.blocked then autoStatus = autoStatus .. "/STOP" end
  local screenWidth, screenHeight = ensureMonitorLayout(display)
  local columns = screenWidth >= 20 and 2 or 1
  local itemCount = 7
  local buttonRows = math.ceil(itemCount / columns)
  local buttonStart = math.max(2, screenHeight - buttonRows + 1)
  line(display, 2, ("AUTO: %s  recipes=%d"):format(autoStatus, enabledAutoCount(recipes)),
    autoState.blocked and colors.red or colors.lightBlue)
  if buttonStart >= 9 then
    line(display, 3, ("STORAGE: %d  slots: %d/%d"):format(storageCount, usedSlots, totalSlots))
    line(display, 4, ("DISPLAY: %s  KEY: %s"):format(
      state.display_mode, P.keyboard_name and "ON" or "OFF"), colors.lightGray)
    line(display, 5, "STAGING: " .. stagingSummary())
    line(display, 6, "TRANSFER: " .. tostring(P.turtle_inventory_name or "staging fallback"))
    line(display, 7, "JOB: " .. tostring(state.auto_current or "idle"), colors.lightBlue)
    line(display, 8, ("BUILD: %s %s"):format(
      shortName(buildInfo.commit, 10), tostring(buildInfo.time):gsub("T", " "):sub(1, 16)
    ), colors.lightGray)
  elseif buttonStart >= 6 then
    line(display, 3, ("STORAGE %d  SLOTS %d/%d"):format(storageCount, usedSlots, totalSlots))
    line(display, 4, ("DISPLAY %s KEY %s"):format(state.display_mode, P.keyboard_name and "ON" or "OFF"), colors.lightGray)
    line(display, 5, "JOB: " .. tostring(state.auto_current or "idle"), colors.lightBlue)
  end
  if buttonStart > 2 then
    line(display, buttonStart - 1, state.message, state.error ~= "" and colors.red or colors.lightGray)
  end
  buttonGrid(display, buttonStart, {
    { label = "AUTO", action = { kind = "global_auto" } },
    { label = "CRAFT", action = { kind = "recipes" } },
    { label = "RECIPES", action = { kind = "recipes" } },
    { label = "REGISTER", action = { kind = "register" } },
    { label = "STOCK", action = { kind = "stock" } },
    { label = "QUEUE", action = { kind = "queue" } },
    { label = "SETTINGS", action = { kind = "settings" } },
  }, columns)
end

local function drawRegister(display)
  drawHeader(display, "REGISTER RECIPE")
  local _, screenHeight = ensureMonitorLayout(display)
  local grid, reason = captureGrid()
  -- Do not show an old preview when the physical Crafty grid is empty.
  -- The register screen must reflect the current turtle inventory.
  state.preview = grid or emptyGrid()
  line(display, 2, "Grid: 1 2 3 / 5 6 7 / 9 10 11", colors.lightGray)
  if not grid then line(display, 3, reason, colors.red) end
  drawGrid(display, state.preview, 3)
  local buttonStart = math.max(7, screenHeight - 1)
  if buttonStart > 7 then line(display, buttonStart - 1, state.message, state.error ~= "" and colors.red or colors.lightGray) end
  buttonGrid(display, buttonStart, {
    { label = monitorLayout.compact and "TEST" or "TEST & REGISTER", action = { kind = "test_register" } },
    { label = "CAPTURE", action = { kind = "capture" } },
    { label = "CANCEL", action = { kind = "home" } },
  }, 2)
end

local function drawRecipes(display)
  drawHeader(display, "RECIPES")
  local screenWidth, screenHeight = ensureMonitorLayout(display)
  local recipes = loadRecipes()
  local keys = recipeKeys(recipes)
  local buttonStart = math.max(4, screenHeight - 1)
  local firstListRow, lastListRow = 3, buttonStart - 2
  local visible = math.max(1, math.min(cfg.page_size, lastListRow - firstListRow + 1))
  local pages = math.max(1, math.ceil(#keys / visible))
  state.recipes_page = math.max(1, math.min(state.recipes_page, pages))
  local first = (state.recipes_page - 1) * visible + 1
  line(display, 2, ("Page %d/%d"):format(state.recipes_page, pages), colors.lightGray)
  for offset = 0, visible - 1 do
    local name = keys[first + offset]
    if name then
      local recipe = recipes[name]
      local row = firstListRow + offset
      line(display, row, ("%-" .. math.max(1, screenWidth - 11) .. "s"):format(
        shortName(name, math.max(1, screenWidth - 11))
      ))
      button(display, math.max(1, screenWidth - 8), row, 6, "OPEN", { kind = "recipe", name = name })
    end
  end
  buttonGrid(display, buttonStart, {
    { label = "<", action = { kind = "recipes_prev" } },
    { label = ">", action = { kind = "recipes_next" } },
    { label = "REGISTER", action = { kind = "register" } },
    { label = "HOME", action = { kind = "home" } },
  }, 2)
end

local function drawDetail(display)
  local recipe = state.selected
  drawHeader(display, "RECIPE DETAIL")
  local _, screenHeight = ensureMonitorLayout(display)
  local buttonStart = math.max(9, screenHeight - 3)
  if not recipe then
    line(display, 3, "No recipe selected", colors.red)
    button(display, 1, buttonStart, 8, "HOME", { kind = "home" })
    return
  end
  line(display, 2, recipe.name, colors.white)
  line(display, 3, recipe.output.displayName or recipe.output.name)
  line(display, 4, recipe.output.name)
  line(display, 5, ("OUTPUT/CRAFT: %d"):format(recipe.output.count))
  line(display, 6, ("STOCK: %d  TARGET: %d"):format(
    finishedStockCount(recipe.output.name), recipe.target or cfg.target_stock
  ))
  line(display, 7, ("AUTO: %s  Global: %s"):format(
    recipeAutoEnabled(recipe.name) and "ON" or "OFF", autoState.global and "ON" or "OFF"
  ), recipeAutoEnabled(recipe.name) and colors.lightBlue or colors.lightGray)
  drawGrid(display, recipe.grid, 8)
  if buttonStart > 9 then line(display, buttonStart - 1, state.message, state.error ~= "" and colors.red or colors.lightGray) end
  buttonGrid(display, buttonStart, {
    { label = "CRAFT 1", action = { kind = "craft", amount = 1 } },
    { label = "CRAFT 16", action = { kind = "craft", amount = 16 } },
    { label = "CRAFT 64", action = { kind = "craft", amount = 64 } },
    { label = monitorLayout.compact and "AUTO" or (recipeAutoEnabled(recipe.name) and "AUTO OFF" or "AUTO ON"), action = { kind = "recipe_auto" } },
    { label = "DELETE", action = { kind = "delete" } },
    { label = "RECIPES", action = { kind = "recipes" } },
    { label = "TARGET", action = { kind = "target" } },
    { label = "HOME", action = { kind = "home" } },
  }, 2)
end

local function drawTarget(display)
  drawHeader(display, "SET TARGET")
  local recipe = state.selected
  if not recipe then
    line(display, 3, "No recipe selected", colors.red)
    button(display, 1, 5, 8, "HOME", { kind = "home" })
    return
  end
  local _, screenHeight = ensureMonitorLayout(display)
  local value = math.max(0, math.floor(tonumber(state.target_value) or recipe.target or cfg.target_stock))
  state.target_value = value
  line(display, 2, recipe.name, colors.white)
  line(display, 3, ("STOCK: %d"):format(finishedStockCount(recipe.output.name)), colors.lightBlue)
  line(display, 4, ("TARGET: %d"):format(value), colors.yellow)
  line(display, 5, ("OUTPUT/CRAFT: %d"):format(recipe.output.count), colors.lightGray)
  line(display, 6, "Adjust with touch, then SAVE", colors.lightGray)
  local buttonStart = math.max(8, screenHeight - 4)
  if buttonStart > 8 then line(display, buttonStart - 1, state.message, state.error ~= "" and colors.red or colors.lightGray) end
  buttonGrid(display, buttonStart, {
    { label = "-1", action = { kind = "target_adjust", amount = -1 } },
    { label = "+1", action = { kind = "target_adjust", amount = 1 } },
    { label = "-16", action = { kind = "target_adjust", amount = -16 } },
    { label = "+16", action = { kind = "target_adjust", amount = 16 } },
    { label = "-64", action = { kind = "target_adjust", amount = -64 } },
    { label = "+64", action = { kind = "target_adjust", amount = 64 } },
    { label = "0", action = { kind = "target_set", value = 0 } },
    { label = "SAVE", action = { kind = "target_save" } },
    { label = "CANCEL", action = { kind = "detail" } },
  }, 2)
end

local function drawStock(display)
  local entries, reason = stockEntries(state.stock_query)
  drawHeader(display, "WAREHOUSE")
  local screenWidth, screenHeight = ensureMonitorLayout(display)
  local buttonStart = math.max(7, screenHeight - 2)
  line(display, 2, ("sort=%s ids=%s search=%s"):format(
    state.stock_sort, state.stock_show_ids and "on" or "off", state.stock_query ~= "" and state.stock_query or "-"
  ), colors.lightGray)
  line(display, 3, ("STORAGE=%d  items=%d"):format(#P.storage, #entries), colors.lightBlue)
  local lastListRow = buttonStart - 2
  local visible = math.max(1, math.min(cfg.page_size, lastListRow - 3 + 1))
  local pages = math.max(1, math.ceil(#entries / visible))
  state.stock_page = math.max(1, math.min(state.stock_page, pages))
  local first = (state.stock_page - 1) * visible + 1
  for offset = 0, visible - 1 do
    local entry = entries[first + offset]
    if entry then
      local label = state.stock_show_ids and entry.name or entry.displayName or shortName(entry.name, 24)
      line(display, 4 + offset, ("%8d  %s"):format(entry.count, shortName(label, math.max(1, screenWidth - 10))))
    end
  end
  if reason and buttonStart > 4 then line(display, buttonStart - 1, reason, colors.red) end
  buttonGrid(display, buttonStart, {
    { label = "<", action = { kind = "stock_prev" } },
    { label = ">", action = { kind = "stock_next" } },
    { label = "SEARCH", action = { kind = "stock_search" } },
    { label = "SORT", action = { kind = "stock_sort" } },
    { label = "ID", action = { kind = "stock_ids" } },
    { label = "REFRESH", action = { kind = "refresh" } },
    { label = "HOME", action = { kind = "home" } },
  }, 2)
end

local function drawQueue(display)
  drawHeader(display, "QUEUE")
  local _, screenHeight = ensureMonitorLayout(display)
  local buttonStart = math.max(5, screenHeight - 1)
  local queue = loadQueue()
  if state.queue_job then line(display, 3, "RUNNING: " .. recipeName(state.queue_job.recipe), colors.lightBlue) end
  for index, job in ipairs(queue) do
    if 3 + index < buttonStart - 1 then
      line(display, 3 + index, ("%d. %-22s x%d"):format(index, shortName(recipeName(job.recipe), 22), job.amount))
    end
  end
  buttonGrid(display, buttonStart, {
    { label = "CLEAR", action = { kind = "queue_clear" } },
    { label = "REFRESH", action = { kind = "refresh" } },
    { label = "HOME", action = { kind = "home" } },
  }, 2)
end

local function drawSettings(display)
  drawHeader(display, "SETTINGS")
  local screenWidth, screenHeight = ensureMonitorLayout(display)
  local buttonStart = math.max(5, screenHeight - 2)
  resolvePeripherals()
  local pageSize = math.max(1, math.min(7, buttonStart - 3))
  local pages = math.max(1, math.ceil(#P.inventories / pageSize))
  state.storage_page = math.max(1, math.min(state.storage_page, pages))
  line(display, 2, ("Inventories Page %d/%d"):format(state.storage_page, pages), colors.lightGray)
  local first = (state.storage_page - 1) * pageSize + 1
  for offset = 0, pageSize - 1 do
    local entry = P.inventories[first + offset]
    if entry then
      local row = 3 + offset
      local roleX = math.max(1, screenWidth - 11)
      lineAt(display, 1, row, shortName(entry.name, math.max(1, roleX - 2)))
      button(display, roleX, row, 9, entry.role, { kind = "storage_role", name = entry.name })
    end
  end
  if buttonStart > 8 then
    line(display, buttonStart - 5, "Tap role: STORAGE/STAGING/CRAFTER/OUTPUT/IGNORE", colors.lightGray)
    line(display, buttonStart - 4, "staging: " .. stagingSummary(),
    P.staging_network_name and colors.lightBlue or colors.red)
    line(display, buttonStart - 3, "turtle: " .. tostring(P.turtle_inventory_name or "unavailable"),
    P.turtle_inventory_name and colors.lightBlue or colors.red)
    line(display, buttonStart - 2, "craft: " .. tostring(P.craft_name or "turtle.craft"))
    line(display, buttonStart - 1, "AUTO: " .. (autoState.global and "ON" or "OFF") ..
    (autoState.blocked and " (STOPPED)" or ""))
    if buttonStart > 9 then
      line(display, buttonStart - 6, "DISPLAY: " .. state.display_mode .. " key=" ..
        tostring(P.keyboard_name or "off"), colors.lightGray)
    end
  end
  buttonGrid(display, buttonStart, {
    { label = "<", action = { kind = "storage_prev" } },
    { label = ">", action = { kind = "storage_next" } },
    { label = "SCAN", action = { kind = "scan" } },
    { label = "AUTO", action = { kind = "global_auto" } },
    { label = "HOME", action = { kind = "home" } },
  }, 2)
end

local function draw(display)
  ensureMonitorLayout(display)
  if state.page == "register" then drawRegister(display)
  elseif state.page == "recipes" then drawRecipes(display)
  elseif state.page == "detail" then drawDetail(display)
  elseif state.page == "target" then drawTarget(display)
  elseif state.page == "stock" then drawStock(display)
  elseif state.page == "queue" then drawQueue(display)
  elseif state.page == "settings" then drawSettings(display)
  else drawHome(display) end
end

local function terminalSearch()
  local old = term.current()
  term.redirect(term.native())
  term.clear()
  term.setCursorPos(1, 1)
  write("Stock search (blank = all): ")
  local query = read()
  state.stock_query = query or ""
  state.stock_page = 1
  term.redirect(old)
end

local function handleAction(action)
  local kind = type(action) == "table" and action.kind or action
  if kind == "home" then state.page = "home"
  elseif kind == "register" then state.page, state.preview = "register", gridSnapshot()
  elseif kind == "capture" then
    local grid, reason = captureGrid()
    if grid then state.preview, state.message, state.error = grid, "CAPTURED preview", ""
    else state.preview, state.message = emptyGrid(), ""; setMessage(reason, true) end
  elseif kind == "test_register" then
    local ok, result = testAndRegister()
    if ok then state.selected, state.page, state.error = result, "detail", ""
    else setMessage(result, true) end
  elseif kind == "recipes" then state.page = "recipes"
  elseif kind == "recipes_prev" then state.recipes_page = math.max(1, state.recipes_page - 1)
  elseif kind == "recipes_next" then state.recipes_page = state.recipes_page + 1
  elseif kind == "recipe" then
    state.selected = loadRecipes()[action.name]
    state.page = "detail"
  elseif kind == "craft" then
    if state.selected then
      queueAdd(state.selected, action.amount, false)
      setMessage(("キューへ追加: %s x%d"):format(state.selected.name, action.amount), false)
      state.page = "queue"
    end
  elseif kind == "global_auto" then
    toggleGlobalAuto()
  elseif kind == "recipe_auto" then
    toggleRecipeAuto(state.selected)
  elseif kind == "target" then
    if state.selected then
      state.target_value = math.max(0, math.floor(tonumber(state.selected.target) or cfg.target_stock))
      state.page = "target"
    end
  elseif kind == "target_adjust" then
    if state.selected then
      state.target_value = math.max(0, math.floor(tonumber(state.target_value) or state.selected.target or cfg.target_stock)
        + math.floor(tonumber(action.amount) or 0))
    end
  elseif kind == "target_set" then
    if state.selected then state.target_value = math.max(0, math.floor(tonumber(action.value) or 0)) end
  elseif kind == "target_save" then
    if state.selected then
      local recipes = loadRecipes()
      local stored = recipes[state.selected.name]
      if stored then
        stored.target = math.max(0, math.floor(tonumber(state.target_value) or cfg.target_stock))
        saveRecipes(recipes)
        state.selected = normalizeRecipe(stored)
        state.target_value = state.selected.target
        state.page = "detail"
        setMessage(("%s Target=%d に変更しました。"):format(state.selected.name, state.target_value), false)
      else
        setMessage("レシピが見つかりません: " .. state.selected.name, true)
      end
    end
  elseif kind == "detail" then
    state.page = "detail"
  elseif kind == "delete" then
    if state.selected then
      local recipes = loadRecipes()
      recipes[state.selected.name] = nil
      saveRecipes(recipes)
      setMessage("削除しました: " .. state.selected.name, false)
      state.selected, state.page = nil, "recipes"
    end
  elseif kind == "stock" then state.page, state.stock_page = "stock", 1
  elseif kind == "stock_prev" then state.stock_page = math.max(1, state.stock_page - 1)
  elseif kind == "stock_next" then state.stock_page = state.stock_page + 1
  elseif kind == "stock_search" then terminalSearch()
  elseif kind == "stock_sort" then state.stock_sort = state.stock_sort == "name" and "count" or "name"
  elseif kind == "stock_ids" then state.stock_show_ids = not state.stock_show_ids
  elseif kind == "queue" then state.page = "queue"
  elseif kind == "queue_clear" then saveQueue({}); setMessage("キューを消去しました。", false)
  elseif kind == "settings" then state.page = "settings"
  elseif kind == "storage_prev" then state.storage_page = math.max(1, state.storage_page - 1)
  elseif kind == "storage_next" then state.storage_page = state.storage_page + 1
  elseif kind == "storage_role" then
    local current = roleFor(action.name)
    local index = 1
    for i, role in ipairs(STORAGE_ROLES) do
      if role == current then index = i break end
    end
    local nextRole = STORAGE_ROLES[(index % #STORAGE_ROLES) + 1]
    local ok, reason = setStorageRole(action.name, nextRole)
    if not ok then setMessage(reason, true) else setMessage(action.name .. " = " .. nextRole, false) end
  elseif kind == "scan" then scan(); setMessage("scan完了", false)
  elseif kind == "refresh" then resetPeripherals(); resolvePeripherals(true); setMessage("refresh完了", false)
  end
end

local function keyIs(key, name)
  return type(keys) == "table" and keys[name] ~= nil and key == keys[name]
end

-- Keyboard input is deliberately mapped to the same actions as touch input.
-- This keeps AUTO/Target/Queue state changes in one place and makes the
-- shortcuts usable with either Tom's native events or standard CC:T events.
local function actionForKey(key)
  if keyIs(key, "escape") then
    if state.page == "detail" then return { kind = "recipes" } end
    if state.page == "target" then return { kind = "detail" } end
    return { kind = "home" }
  end
  if keyIs(key, "home") or keyIs(key, "h") then return { kind = "home" } end
  if keyIs(key, "r") then return { kind = "recipes" } end
  if keyIs(key, "s") then return { kind = "stock" } end
  if keyIs(key, "q") then return { kind = "queue" } end
  if keyIs(key, "i") then return { kind = "register" } end

  if state.page == "home" and keyIs(key, "a") then
    return { kind = "global_auto" }
  elseif state.page == "detail" then
    if keyIs(key, "a") then return { kind = "recipe_auto" } end
    if keyIs(key, "t") then return { kind = "target" } end
    if keyIs(key, "one") then return { kind = "craft", amount = 1 } end
    if keyIs(key, "two") then return { kind = "craft", amount = 16 } end
    if keyIs(key, "three") then return { kind = "craft", amount = 64 } end
    if keyIs(key, "delete") then return { kind = "delete" } end
  elseif state.page == "target" then
    if keyIs(key, "enter") then return { kind = "target_save" } end
    if keyIs(key, "left") then return { kind = "target_adjust", amount = -1 } end
    if keyIs(key, "right") then return { kind = "target_adjust", amount = 1 } end
  elseif state.page == "recipes" then
    if keyIs(key, "left") then return { kind = "recipes_prev" } end
    if keyIs(key, "right") then return { kind = "recipes_next" } end
  elseif state.page == "stock" then
    if keyIs(key, "left") then return { kind = "stock_prev" } end
    if keyIs(key, "right") then return { kind = "stock_next" } end
  end
  return nil
end

local function actionForChar(character)
  if state.page == "target" then
    if character == "+" or character == "=" then return { kind = "target_adjust", amount = 1 } end
    if character == "-" or character == "_" then return { kind = "target_adjust", amount = -1 } end
  end
  return nil
end

local function runKeyboardAction(action)
  if not action then return end
  local ok, reason = pcall(handleAction, action)
  if not ok then setMessage(reason, true) end
  state.ui_dirty = true
end

local function guiLoop()
  local monitor = nil
  local gpuDisplay = nil

  local function renderDisplay()
    return gpuDisplay or monitor
  end

  local function reconnect()
    local ok, reason = pcall(resolvePeripherals, true)
    gpuDisplay = nil
    if ok and (P.monitor or P.gpu) then
      monitor = P.monitor
      local monitorOk, monitorReason = true, nil
      if monitor then
        monitorOk, monitorReason = pcall(configureMonitor, monitor)
      end
      if not monitorOk then
        monitor = nil
        setMessage("Monitor初期化失敗: " .. tostring(monitorReason), true)
      end

      if P.gpu then
        local gpuOk, gpuReason = pcall(function()
          -- newGpuDisplay follows Tom's NeoForge-safe window drawing path.
          local candidate = newGpuDisplay(P.gpu)
          configureMonitor(candidate)
          gpuDisplay = candidate
        end)
        if not gpuOk then
          log("WARN", "Tom's GPU disabled: " .. tostring(gpuReason))
          gpuDisplay = nil
          if not monitor then setMessage("GPU初期化失敗: " .. tostring(gpuReason), true) end
        end
      end

      if renderDisplay() then
        state.display_mode = gpuDisplay and "gpu" or "monitor"
        state.error = ""
      else
        setMessage("描画面が未接続です", true)
      end
    else
      monitor = nil
      gpuDisplay = nil
      setMessage("Peripheral再接続待ち: " .. tostring(reason or "Monitorが未接続です"), true)
    end
  end
  reconnect()
  state.timer = os.startTimer(cfg.refresh_seconds)

  local function redraw()
    local display = renderDisplay()
    if not display then return end
    local drawn, reason = pcall(draw, display)
    if drawn then
      if gpuDisplay then
        local synced, syncReason = pcall(gpuDisplay.sync)
        if not synced then
          log("WARN", "Tom's GPU sync failed: " .. tostring(syncReason))
          gpuDisplay = nil
          state.display_mode = "monitor"
          state.ui_dirty = true
          return false
        end
      end
      state.ui_dirty = false
      return true
    end
    setMessage("Monitor更新失敗: " .. tostring(reason), true)
    local recovered = pcall(function()
      configureMonitor(display)
      display.setBackgroundColor(colors.black)
      display.clear()
      state.buttons = {}
      line(display, 1, "FACTORY", colors.yellow)
      line(display, 3, "GUI ERROR", colors.red)
      line(display, 4, tostring(reason), colors.red)
      if gpuDisplay then gpuDisplay.sync() end
    end)
    if not recovered then
      if gpuDisplay then
        gpuDisplay = nil
        state.display_mode = "monitor"
        state.ui_dirty = true
      else
        resetPeripherals()
        monitor = nil
      end
    end
    return false
  end

  -- Draw once before waiting. Do not draw at the top of every event loop:
  -- queueLoop emits a 0.2 second timer, and clearing the monitor for each of
  -- those unrelated events makes a small Advanced Monitor visibly flicker.
  redraw()
  pcall(updateBuildInfo)
  if state.ui_dirty then redraw() end

  local function jobKey(job)
    if not job then return "" end
    return recipeName(job.recipe) .. ":" .. tostring(job.amount)
  end

  while true do
    local event, a, b, c = os.pullEventRaw()
    if event == "terminate" then return
    elseif monitor and event == "monitor_touch" and a == P.monitor_name then
      for _, hit in ipairs(state.buttons) do
        if b >= hit.x1 and b <= hit.x2 and c >= hit.y1 and c <= hit.y2 then
          local ok, reason = pcall(handleAction, hit.action)
          if not ok then setMessage(reason, true) end
          redraw()
          break
        end
      end
    elseif gpuDisplay and event == "tm_monitor_touch" then
      local x, y = gpuDisplay.pixelToCell(a, b)
      for _, hit in ipairs(state.buttons) do
        if x >= hit.x1 and x <= hit.x2 and y >= hit.y1 and y <= hit.y2 then
          runKeyboardAction(hit.action)
          redraw()
          break
        end
      end
    elseif gpuDisplay and event == "tm_monitor_mouse_click" and c == 1 then
      local x, y = gpuDisplay.pixelToCell(a, b)
      for _, hit in ipairs(state.buttons) do
        if x >= hit.x1 and x <= hit.x2 and y >= hit.y1 and y <= hit.y2 then
          runKeyboardAction(hit.action)
          redraw()
          break
        end
      end
    elseif event == "key" and b ~= true then
      local action = actionForKey(a)
      if action then runKeyboardAction(action); redraw() end
    elseif event == "char" then
      local action = actionForChar(a)
      if action then runKeyboardAction(action); redraw() end
    elseif event == "tm_keyboard_key" and a == P.keyboard_name and c ~= true then
      local action = actionForKey(b)
      if action then runKeyboardAction(action); redraw() end
    elseif event == "tm_keyboard_char" and a == P.keyboard_name then
      local action = actionForChar(b)
      if action then runKeyboardAction(action); redraw() end
    elseif event == "timer" and a == state.timer then
      state.timer = os.startTimer(cfg.refresh_seconds)
      local beforeAuto = state.auto_current
      local beforeJob = jobKey(state.queue_job)
      local beforeStock = stockCache.signature
      local refreshed, refreshReason = pcall(refreshStockCache, false)
      if not refreshed then
        setMessage("在庫更新失敗: " .. tostring(refreshReason), true)
      elseif beforeAuto ~= state.auto_current
        or beforeJob ~= jobKey(state.queue_job)
        or beforeStock ~= stockCache.signature then
        state.ui_dirty = true
      end
      if state.ui_dirty then redraw() end
    elseif event == "peripheral" or event == "peripheral_detach" then
      resetPeripherals()
      reconnect()
      redraw()
    end
  end
end

local function runGui()
  scan()
  local ok, reason = pcall(function() parallel.waitForAny(guiLoop, queueLoop) end)
  if not ok and tostring(reason) ~= "Terminated" then
    log("ERROR", reason)
    print("Factory GUI error: " .. tostring(reason))
  end
end

local function printGrid(grid)
  for row = 1, 3 do
    local parts = {}
    for column = 1, 3 do
      local entry = grid[(row - 1) * 3 + column]
      parts[#parts + 1] = entry == "" and "-" or entry.name
    end
    print(table.concat(parts, " | "))
  end
end

local function cliRecipes(args)
  local action = args[2] or "list"
  local recipes = loadRecipes()
  if action == "list" then
    for _, name in ipairs(recipeKeys(recipes)) do
      local recipe = recipes[name]
      print(("%s -> %s x%d / stock=%d / %s"):format(
        name, recipe.output.name, recipe.output.count, finishedStockCount(recipe.output.name), recipeSummary(recipe)
      ))
    end
  elseif action == "capture" then
    local ok, result = testAndRegister()
    if ok then print("REGISTERED: " .. result.name)
    else print("NOT REGISTERED: " .. tostring(result)) end
  elseif action == "show" then
    local recipe = findRecipe(recipes, args[3])
    if not recipe then error("レシピがありません。", 0) end
    print("name: " .. recipe.name)
    print("output: " .. recipe.output.name .. " x" .. recipe.output.count)
    print("display: " .. tostring(recipe.output.displayName))
    print("stock: " .. finishedStockCount(recipe.output.name))
    print("target: " .. tostring(recipe.target or cfg.target_stock))
    printGrid(recipe.grid)
  elseif action == "remove" or action == "delete" then
    local name = args[3]
    if not name or not recipes[name] then error("レシピがありません: " .. tostring(name), 0) end
    recipes[name] = nil
    saveRecipes(recipes)
    print("削除しました: " .. name)
  else
    print("recipe list|capture|show <name>|remove <name>")
  end
end

local function cliStock(args)
  local query = args[2] == "search" and args[3] or args[2] or ""
  for _, entry in ipairs(stockEntries(query)) do
    print(("%8d  %s"):format(entry.count, entry.name))
  end
end

local function cliStorage(args)
  local action = args[2] or "list"
  resolvePeripherals(true)
  if action == "list" then
    for _, entry in ipairs(P.inventories) do
      print(("%-32s %s"):format(entry.name, entry.role))
    end
    print("turtle inventory: " .. tostring(P.turtle_inventory_name or "unavailable"))
    print("staging local: " .. tostring(P.staging_local_name or "unavailable"))
    print("staging network: " .. tostring(P.staging_network_name or "unavailable"))
  elseif action == "set" then
    local name, role = args[3], args[4]
    local ok, reason = setStorageRole(name, role)
    if not ok then error(reason, 0) end
    print(name .. " = " .. tostring(role):upper())
  elseif action == "reset" then
    if not args[3] then error("inventory名が必要です。", 0) end
    storageState.roles[args[3]] = nil
    saveStorageConfig()
    resetPeripherals()
    print("role reset: " .. args[3])
  else
    print("storage list|set <peripheral> <STORAGE|STAGING|CRAFTER|OUTPUT|IGNORE>|reset <peripheral>")
  end
end

local function cliVersion()
  local ok, reason = updateBuildInfo()
  print("Factory OS")
  print("GitHub commit: " .. tostring(buildInfo.commit))
  print("Commit time: " .. tostring(buildInfo.time))
  if not ok then print("Remote check: " .. tostring(reason)) end
end

local function cliGpu()
  local ok, p = pcall(resolvePeripherals, true)
  if not ok then error(p, 0) end
  if not p.gpu then error("Tom's GPUが見つかりません。factory scanを確認してください。", 0) end
  local surface = newGpuDisplay(p.gpu)
  configureMonitor(surface)
  surface.setBackgroundColor(colors.black)
  surface.clear()
  state.buttons = {}
  line(surface, 1, "GPU TEST", colors.yellow)
  line(surface, 2, "factory gpu OK", colors.lightBlue)
  line(surface, 3, ("size %dx%d"):format(monitorLayout.width, monitorLayout.height), colors.white)
  surface.sync()
  print("GPU test frame sent: " .. tostring(monitorLayout.width) .. "x" .. tostring(monitorLayout.height))
end

local function cliCraft(args)
  local recipes = loadRecipes()
  local recipe = findRecipe(recipes, args[2])
  if not recipe then error("レシピがありません: " .. tostring(args[2]), 0) end
  local amount = args[3]
  if not amount or amount == "auto" then
    local ok, reason = queueAuto(recipe)
    print(reason)
    if not ok then return end
  else
    amount = tonumber(amount)
    if not amount or amount < 1 then error("countは1以上の数値、またはautoです。", 0) end
    queueAdd(recipe, amount)
    print(("キューへ追加: %s x%d"):format(recipe.name, amount))
  end
  while true do
    local queue = loadQueue()
    if not queue[1] then break end
    if not processQueueOnce() then break end
  end
end

loadAuto()
loadStorageConfig()

local args = { ... }
local mode = args[1] or "dashboard"
local ok, reason = pcall(function()
  if mode == "scan" then scan()
  elseif mode == "dashboard" or mode == "gui" then runGui()
  elseif mode == "version" then cliVersion()
  elseif mode == "gpu" then cliGpu()
  elseif mode == "recipe" then cliRecipes(args)
  elseif mode == "stock" then cliStock(args)
  elseif mode == "storage" then cliStorage(args)
  elseif mode == "craft" then cliCraft(args)
  elseif mode == "queue" then
    if args[2] == "clear" then saveQueue({}); print("キューを消去しました。")
    else
      for index, job in ipairs(loadQueue()) do print(("%d. %s x%d"):format(index, recipeName(job.recipe), job.amount)) end
    end
  else
    print("factory dashboard")
    print("factory version")
    print("factory gpu")
    print("factory scan")
    print("factory recipe list|capture|show <name>|remove <name>")
    print("factory stock [search <text>]")
    print("factory storage list|set <peripheral> <STORAGE|STAGING|CRAFTER|OUTPUT|IGNORE>|reset <peripheral>")
    print("factory craft <name> [count|auto]")
    print("factory queue list|clear")
  end
end)
if not ok then
  log("ERROR", reason)
  print("ERROR: " .. tostring(reason))
end
