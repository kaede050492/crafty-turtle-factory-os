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
  staging_inventory = "AUTO", -- dedicated inventory above the turtle
  staging_side = "top",       -- turtle.suckUp() source
  craft_peripheral = "AUTO",   -- normally left=workbench/craft
  monitor = "AUTO",
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
}

-- The physical Crafty Turtle grid is not logical slots 1..9.
local CRAFT_SLOTS = { 1, 2, 3, 5, 6, 7, 9, 10, 11 }
local NON_GRID_SLOTS = { 4, 8, 12, 13, 14, 15, 16 }

local state = {
  page = "home",
  message = "",
  error = "",
  selected = nil,
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
  totals = {},
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
  manager_name = nil,
  manager = nil,
  turtle_inventory_name = nil,
  turtle_inventory = nil,
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
  log(isError and "ERROR" or "INFO", state.message)
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

local function typeMatches(name, expected)
  for _, actual in ipairs({ peripheral.getType(name) }) do
    if actual == expected then return true end
  end
  return false
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
  P.manager = nil
  P.turtle_inventory_name = nil
  P.turtle_inventory = nil
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
  if name == P.turtle_inventory_name then
    return "IGNORE"
  end
  return "STORAGE"
end

local function roleFor(name)
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
  P.manager_name, P.manager = configured(managerName) and managerName or nil, manager
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

  local stagingName = cfg.staging_inventory
  if stagingName == "AUTO" then
    if peripheral.isPresent(cfg.staging_side) and isTransferInventory(cfg.staging_side)
      and roleFor(cfg.staging_side) == "STAGING" then
      stagingName = cfg.staging_side
    else
      for _, name in ipairs(sortedPeripheralNames()) do
        if roleFor(name) == "STAGING" and isTransferInventory(name) then
          stagingName = name
          break
        end
      end
    end
  end
  local staging = configured(stagingName) and peripheral.wrap(stagingName) or nil
  if not staging or not isTransferInventory(stagingName) then
    stagingName, staging = nil, nil
  end
  if stagingName and stagingName ~= cfg.staging_side then
    log("ERROR", "STAGINGは" .. cfg.staging_side .. "側に必要です: " .. stagingName)
    stagingName, staging = nil, nil
  end
  P.staging_name, P.staging = stagingName, staging
  scanInventories()
  state.monitor_name = P.monitor_name
  return P
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
    print("staging inventory: " .. tostring(p.staging_name or "unavailable"))
    print("STORAGE inventories: " .. tostring(#p.storage))
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
    return false, "roleは STORAGE / CRAFTER / OUTPUT / IGNORE のいずれかです。"
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
  local displayNames = {}
  for _, inventory in pairs(inventories) do
    for slot, stack in pairs(inventory.stacks) do
      if stack and stack.name then
        totals[stack.name] = (totals[stack.name] or 0) + (stack.count or 0)
        if stack.displayName then displayNames[stack.name] = stack.displayName end
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
  stockCache.totals = totals
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

local function storageSummary()
  local cache = refreshStockCache(false)
  return #P.storage, cache.usedSlots or 0, cache.totalSlots or 0
end

local function outputStock(name)
  resolvePeripherals()
  local total = 0
  for _, entry in ipairs(P.outputs) do
    local stacks = inventoryStacks(entry.object)
    for _, stack in pairs(stacks) do
      if stack and stack.name == name then total = total + (stack.count or 0) end
    end
  end
  return #P.outputs > 0 and total or nil
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
  if not P.staging_name or not P.staging then
    return false, "STAGING inventoryが見つかりません。"
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
  local callOk, moved = pcall(source.object.pushItems, P.staging_name,
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
        local callOk = type(P.staging.pushItems) == "function"
        if callOk then
          pcall(P.staging.pushItems, destination.name, slot, remaining)
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
  if cfg.output_side and peripheral.isPresent(cfg.output_side) then
    return dropSlotDown(slot, amount)
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

local function queueAuto(recipe)
  local current = stockCount(recipe.output.name)
  local target = recipe.target or cfg.target_stock
  local missing = target - current
  if missing <= 0 then return false, "在庫 " .. current .. "/" .. target .. "で生産不要です。" end
  local amount = math.max(1, math.ceil(missing / recipe.output.count))
  queueAdd(recipe, amount, false)
  return true, ("AUTOをキューへ追加: %s x%d"):format(recipe.name, amount)
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
        local batch = batchLimit(recipe, cfg.batch_limit, cache)
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

local function line(display, y, text, colour)
  local width, height = display.getSize()
  if y < 1 or y > height then return end
  if colour then setColour(display, colour, colors.black) end
  display.setCursorPos(1, y)
  display.write(tostring(text or ""):sub(1, width))
end

local function button(display, x, y, width, label, action)
  local screenWidth, height = display.getSize()
  if y < 1 or y > height or x > screenWidth then return end
  local text = ("[%-" .. width .. "s]"):format(label)
  text = text:sub(1, math.max(1, screenWidth - x + 1))
  display.setCursorPos(x, y)
  display.write(text)
  state.buttons[#state.buttons + 1] = {
    x1 = x, y1 = y, x2 = x + #text - 1, y2 = y, action = action,
  }
end

local function drawGrid(display, grid, top)
  for row = 1, 3 do
    local cells = {}
    for column = 1, 3 do
      local logical = (row - 1) * 3 + column
      local entry = grid and grid[logical] or ""
      local text = type(entry) == "table" and (entry.displayName or entry.name) or entry
      cells[#cells + 1] = ("%-10s"):format(shortName(text, 9))
    end
    line(display, top + row - 1, table.concat(cells, "|"), colors.lightBlue)
  end
end

local function drawHeader(display, text)
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
  line(display, 3, "Crafty Turtle Factory OS", colors.white)
  line(display, 4, ("STORAGE: %d  slots: %d/%d"):format(storageCount, usedSlots, totalSlots))
  line(display, 5, "STAGING: " .. tostring(P.staging_name or "unavailable"))
  line(display, 6, "turtle transfer: " .. tostring(P.turtle_inventory_name or "staging fallback"))
  line(display, 7, "craft: " .. tostring(P.craft_name or "turtle.craft"))
  line(display, 8, state.message, state.error ~= "" and colors.red or colors.lightGray)
  line(display, 9, ("AUTO: %s  recipes=%d"):format(autoStatus, enabledAutoCount(recipes)),
    autoState.blocked and colors.red or colors.lightBlue)
  line(display, 10, "AUTO JOB: " .. tostring(state.auto_current or "idle"), colors.lightBlue)
  button(display, 1, 11, 10, autoState.global and "AUTO OFF" or "AUTO ON", { kind = "global_auto" })
  button(display, 14, 11, 10, "CRAFT", { kind = "recipes" })
  button(display, 28, 11, 11, "RECIPES", { kind = "recipes" })
  button(display, 1, 13, 10, "REGISTER", { kind = "register" })
  button(display, 14, 13, 8, "STOCK", { kind = "stock" })
  button(display, 1, 15, 8, "QUEUE", { kind = "queue" })
  button(display, 14, 15, 8, "SETTINGS", { kind = "settings" })
end

local function drawRegister(display)
  drawHeader(display, "REGISTER RECIPE")
  local grid, reason = captureGrid()
  state.preview = grid or state.preview
  if not grid then line(display, 3, reason, colors.red) end
  line(display, 3, "Physical slots: 1 2 3 / 5 6 7 / 9 10 11", colors.lightGray)
  drawGrid(display, state.preview, 5)
  line(display, 9, "CAPTURE = refresh preview", colors.lightGray)
  line(display, 10, "TEST & REGISTER = craft once, detect output, save", colors.lightGray)
  button(display, 1, 12, 10, "CAPTURE", { kind = "capture" })
  button(display, 13, 12, 17, "TEST & REGISTER", { kind = "test_register" })
  button(display, 32, 12, 8, "CANCEL", { kind = "home" })
  line(display, 14, state.message, state.error ~= "" and colors.red or colors.lightGray)
end

local function drawRecipes(display)
  drawHeader(display, "RECIPES")
  local recipes = loadRecipes()
  local keys = recipeKeys(recipes)
  local pages = math.max(1, math.ceil(#keys / cfg.page_size))
  state.recipes_page = math.max(1, math.min(state.recipes_page, pages))
  local first = (state.recipes_page - 1) * cfg.page_size + 1
  line(display, 2, ("Page %d/%d"):format(state.recipes_page, pages), colors.lightGray)
  for offset = 0, cfg.page_size - 1 do
    local name = keys[first + offset]
    if name then
      local recipe = recipes[name]
      line(display, 3 + offset, ("%-22s %s x%d"):format(
        shortName(name, 22), shortName(recipe.output.name, 16), recipe.output.count
      ))
      button(display, 31, 3 + offset, 9, "OPEN", { kind = "recipe", name = name })
    end
  end
  button(display, 1, 12, 5, "<", { kind = "recipes_prev" })
  button(display, 8, 12, 5, ">", { kind = "recipes_next" })
  button(display, 16, 12, 9, "REGISTER", { kind = "register" })
  button(display, 29, 12, 8, "HOME", { kind = "home" })
end

local function drawDetail(display)
  local recipe = state.selected
  drawHeader(display, "RECIPE DETAIL")
  if not recipe then
    line(display, 3, "No recipe selected", colors.red)
    button(display, 1, 12, 8, "HOME", { kind = "home" })
    return
  end
  line(display, 2, recipe.name, colors.white)
  line(display, 3, recipe.output.displayName or recipe.output.name)
  line(display, 4, recipe.output.name)
  line(display, 5, ("Output: %d  Input: %d  Target: %d"):format(
    recipe.output.count, stockCount(recipe.output.name), recipe.target or cfg.target_stock
  ))
  line(display, 6, ("AUTO: %s  Global: %s"):format(
    recipeAutoEnabled(recipe.name) and "ON" or "OFF", autoState.global and "ON" or "OFF"
  ), recipeAutoEnabled(recipe.name) and colors.lightBlue or colors.lightGray)
  drawGrid(display, recipe.grid, 7)
  button(display, 1, 12, 8, "CRAFT 1", { kind = "craft", amount = 1 })
  button(display, 11, 12, 9, "CRAFT 16", { kind = "craft", amount = 16 })
  button(display, 22, 12, 8, "CRAFT 64", { kind = "craft", amount = 64 })
  button(display, 31, 12, 8, recipeAutoEnabled(recipe.name) and "AUTO OFF" or "AUTO ON", { kind = "recipe_auto" })
  button(display, 1, 14, 8, "DELETE", { kind = "delete" })
  button(display, 12, 14, 8, "RECIPES", { kind = "recipes" })
  button(display, 24, 14, 8, "HOME", { kind = "home" })
  line(display, 16, state.message, state.error ~= "" and colors.red or colors.lightGray)
end

local function drawStock(display)
  local entries, reason = stockEntries(state.stock_query)
  drawHeader(display, "WAREHOUSE")
  line(display, 2, ("sort=%s ids=%s search=%s"):format(
    state.stock_sort, state.stock_show_ids and "on" or "off", state.stock_query ~= "" and state.stock_query or "-"
  ), colors.lightGray)
  line(display, 3, ("STORAGE=%d  items=%d"):format(#P.storage, #entries), colors.lightBlue)
  local pages = math.max(1, math.ceil(#entries / cfg.page_size))
  state.stock_page = math.max(1, math.min(state.stock_page, pages))
  local first = (state.stock_page - 1) * cfg.page_size + 1
  for offset = 0, cfg.page_size - 1 do
    local entry = entries[first + offset]
    if entry then
      local label = state.stock_show_ids and entry.name or entry.displayName or shortName(entry.name, 24)
      line(display, 4 + offset, ("%8d  %s"):format(entry.count, label))
    end
  end
  if reason then line(display, 11, reason, colors.red) end
  button(display, 1, 12, 5, "<", { kind = "stock_prev" })
  button(display, 8, 12, 5, ">", { kind = "stock_next" })
  button(display, 15, 12, 8, "SEARCH", { kind = "stock_search" })
  button(display, 25, 12, 6, "SORT", { kind = "stock_sort" })
  button(display, 33, 12, 7, "ID", { kind = "stock_ids" })
  button(display, 1, 14, 10, "REFRESH", { kind = "refresh" })
  button(display, 28, 14, 8, "HOME", { kind = "home" })
end

local function drawQueue(display)
  drawHeader(display, "QUEUE")
  local queue = loadQueue()
  if state.queue_job then line(display, 3, "RUNNING: " .. recipeName(state.queue_job.recipe), colors.lightBlue) end
  for index, job in ipairs(queue) do
    if index <= 7 then
      line(display, 3 + index, ("%d. %-22s x%d"):format(index, shortName(recipeName(job.recipe), 22), job.amount))
    end
  end
  button(display, 1, 12, 8, "CLEAR", { kind = "queue_clear" })
  button(display, 14, 12, 8, "REFRESH", { kind = "refresh" })
  button(display, 28, 12, 8, "HOME", { kind = "home" })
end

local function drawSettings(display)
  drawHeader(display, "SETTINGS")
  resolvePeripherals()
  local pageSize = 7
  local pages = math.max(1, math.ceil(#P.inventories / pageSize))
  state.storage_page = math.max(1, math.min(state.storage_page, pages))
  line(display, 2, ("Inventories Page %d/%d"):format(state.storage_page, pages), colors.lightGray)
  local first = (state.storage_page - 1) * pageSize + 1
  for offset = 0, pageSize - 1 do
    local entry = P.inventories[first + offset]
    if entry then
      line(display, 3 + offset, ("%-22s"):format(shortName(entry.name, 22)))
      button(display, 28, 3 + offset, 12, entry.role, { kind = "storage_role", name = entry.name })
    end
  end
  line(display, 11, "Tap role: STORAGE/STAGING/CRAFTER/OUTPUT/IGNORE", colors.lightGray)
  line(display, 12, "staging: " .. tostring(P.staging_name or "unavailable"),
    P.staging_name and colors.lightBlue or colors.red)
  line(display, 13, "turtle inventory: " .. tostring(P.turtle_inventory_name or "unavailable"),
    P.turtle_inventory_name and colors.lightBlue or colors.red)
  line(display, 14, "craft: " .. tostring(P.craft_name or "turtle.craft"))
  line(display, 15, "AUTO: " .. (autoState.global and "ON" or "OFF") ..
    (autoState.blocked and " (STOPPED)" or ""))
  button(display, 1, 16, 5, "<", { kind = "storage_prev" })
  button(display, 8, 16, 5, ">", { kind = "storage_next" })
  button(display, 15, 16, 8, "SCAN", { kind = "scan" })
  button(display, 25, 16, 10, autoState.global and "AUTO OFF" or "AUTO ON", { kind = "global_auto" })
  button(display, 36, 16, 5, "HOME", { kind = "home" })
end

local function draw(display)
  if state.page == "register" then drawRegister(display)
  elseif state.page == "recipes" then drawRecipes(display)
  elseif state.page == "detail" then drawDetail(display)
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
    else setMessage(reason, true) end
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

local function guiLoop()
  local monitor = nil
  local function reconnect()
    local ok, reason = pcall(resolvePeripherals, true)
    if ok and P.monitor then
      monitor = P.monitor
      monitor.setTextScale(0.5)
      state.error = ""
    else
      monitor = nil
      setMessage("Peripheral再接続待ち: " .. tostring(reason or "Monitorが未接続です"), true)
    end
  end
  reconnect()
  state.timer = os.startTimer(cfg.refresh_seconds)
  while true do
    if monitor then
      local drawn, reason = pcall(draw, monitor)
      if not drawn then
        setMessage("Monitor更新失敗: " .. tostring(reason), true)
        resetPeripherals()
        monitor = nil
      end
    end
    local event, a, b, c = os.pullEventRaw()
    if event == "terminate" then return
    elseif monitor and event == "monitor_touch" and a == P.monitor_name then
      for _, hit in ipairs(state.buttons) do
        if b >= hit.x1 and b <= hit.x2 and c >= hit.y1 and c <= hit.y2 then
          local ok, reason = pcall(handleAction, hit.action)
          if not ok then setMessage(reason, true) end
          break
        end
      end
    elseif event == "timer" and a == state.timer then
      state.timer = os.startTimer(cfg.refresh_seconds)
    elseif event == "peripheral" or event == "peripheral_detach" then
      resetPeripherals()
      reconnect()
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
        name, recipe.output.name, recipe.output.count, stockCount(recipe.output.name), recipeSummary(recipe)
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
    print("stock: " .. stockCount(recipe.output.name))
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
    print("staging inventory: " .. tostring(P.staging_name or "unavailable"))
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
