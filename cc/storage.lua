-- Computer #2: Wired inventory export controller for CC:Tweaked 1.120.0.
--
-- This program intentionally uses only the generic CC:T inventory API:
-- peripheral.getNames/isPresent/getMethods/getType/wrap, inventory.list,
-- inventory.size, inventory.pushItems, fs, textutils and os events.
--
-- Install as /storage and use:
--   storage list
--   storage set-source <peripheral>
--   storage add <peripheral>
--   storage remove <peripheral>
--   storage status
--   storage run

local CONFIG_FILE = "storage_controller.db"
local TEMP_FILE = CONFIG_FILE .. ".tmp"
local BACKUP_FILE = CONFIG_FILE .. ".bak"
local POLL_SECONDS = 0.2
local MAX_PUSHES_PER_CYCLE = 64

local args = { ... }
local config = {
  source = "",
  storages = {},
}
local loadWarning = nil

local function text(value)
  return tostring(value == nil and "" or value)
end

local function configured(value)
  return type(value) == "string" and value ~= ""
end

local function copyItem(item)
  if type(item) ~= "table" then return nil end
  local result = {}
  for key, value in pairs(item) do result[key] = value end
  return result
end

local function sameStack(a, b)
  return type(a) == "table" and type(b) == "table"
    and a.name == b.name and a.nbt == b.nbt
end

local function normalizeConfig(value)
  local result = { source = "", storages = {} }
  if type(value) ~= "table" then return result end
  if type(value.source) == "string" then result.source = value.source end

  local seen = {}
  if type(value.storages) == "table" then
    for _, name in ipairs(value.storages) do
      if type(name) == "string" and name ~= ""
        and name ~= result.source and not seen[name] then
        seen[name] = true
        result.storages[#result.storages + 1] = name
      end
    end
  end
  return result
end

local function loadConfig()
  if not fs.exists(CONFIG_FILE) then return end
  local handle = fs.open(CONFIG_FILE, "r")
  if not handle then
    loadWarning = "設定ファイルを開けません"
    return
  end
  local body = handle.readAll()
  handle.close()
  local ok, value = pcall(textutils.unserialize, body)
  if not ok or type(value) ~= "table" then
    loadWarning = "設定ファイルが壊れているため初期設定を使用"
    return
  end
  config = normalizeConfig(value)
end

local function writeFile(path, body)
  local handle = fs.open(path, "w")
  if not handle then return false, "ファイルを書き込めません: " .. path end
  handle.write(body)
  handle.close()
  return true
end

local function saveConfig()
  local body = textutils.serialize(config)
  local ok, reason = writeFile(TEMP_FILE, body)
  if not ok then return false, reason end

  local movedOld = false
  if fs.exists(CONFIG_FILE) then
    if fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
    local moved, moveReason = pcall(fs.move, CONFIG_FILE, BACKUP_FILE)
    if not moved then
      if fs.exists(TEMP_FILE) then fs.delete(TEMP_FILE) end
      return false, "既存DBを退避できません: " .. text(moveReason)
    end
    movedOld = true
  end

  local installed, installReason = pcall(fs.move, TEMP_FILE, CONFIG_FILE)
  if not installed then
    if movedOld and not fs.exists(CONFIG_FILE) then
      pcall(fs.move, BACKUP_FILE, CONFIG_FILE)
    end
    if fs.exists(TEMP_FILE) then fs.delete(TEMP_FILE) end
    return false, "新DBを配置できません: " .. text(installReason)
  end

  if movedOld and fs.exists(BACKUP_FILE) then fs.delete(BACKUP_FILE) end
  return true
end

local function hasMethod(methods, wanted)
  for _, method in ipairs(methods or {}) do
    if method == wanted then return true end
  end
  return false
end

local function typeNames(name)
  local typeCallOk, firstType, secondType, thirdType = pcall(peripheral.getType, name)
  if not typeCallOk then return "unknown" end
  local types = { firstType, secondType, thirdType }
  local result = {}
  for _, value in ipairs(types) do
    if value ~= nil then result[#result + 1] = text(value) end
  end
  if #result == 0 then return "unknown" end
  return table.concat(result, ",")
end

local function inventoryInfo(name)
  if not configured(name) then return nil, "Peripheral名が空です" end
  if not peripheral.isPresent(name) then return nil, "未接続です" end

  local methodsOk, methods = pcall(peripheral.getMethods, name)
  if not methodsOk or type(methods) ~= "table" then
    return nil, "getMethods()に失敗しました"
  end
  if not hasMethod(methods, "list") then
    return nil, "list()がありません"
  end
  if not hasMethod(methods, "size") then
    return nil, "size()がありません"
  end

  local wrapped = peripheral.wrap(name)
  if not wrapped then return nil, "wrap()に失敗しました" end
  return {
    name = name,
    object = wrapped,
    methods = methods,
    types = typeNames(name),
    canPush = hasMethod(methods, "pushItems"),
  }
end

local function readList(info)
  local ok, result = pcall(info.object.list)
  if not ok or type(result) ~= "table" then
    return nil, "list()失敗: " .. text(result)
  end
  return result
end

local function readSize(info)
  local ok, result = pcall(info.object.size)
  if not ok or type(result) ~= "number" or result < 1 then
    return nil, "size()失敗: " .. text(result)
  end
  return math.floor(result)
end

local function itemCount(items)
  local total, slots = 0, 0
  for _, item in pairs(items or {}) do
    if type(item) == "table" and type(item.count) == "number" then
      total = total + item.count
      slots = slots + 1
    end
  end
  return total, slots
end

local function sortedItemSlots(items)
  local slots = {}
  for slot, item in pairs(items or {}) do
    if type(slot) == "number" and type(item) == "table" then
      slots[#slots + 1] = slot
    end
  end
  table.sort(slots)
  return slots
end

local function removeStorage(name)
  local changed = false
  local kept = {}
  for _, value in ipairs(config.storages) do
    if value == name then
      changed = true
    else
      kept[#kept + 1] = value
    end
  end
  config.storages = kept
  return changed
end

local function usage()
  print("Usage:")
  print("  storage list")
  print("  storage set-source <peripheral>")
  print("  storage add <peripheral>")
  print("  storage remove <peripheral>")
  print("  storage status")
  print("  storage run")
end

local function cmdList()
  print("Connected inventory peripherals:")
  local names = peripheral.getNames()
  table.sort(names)
  local discovered = 0
  for _, name in ipairs(names) do
    local info, reason = inventoryInfo(name)
    if info then
      discovered = discovered + 1
      local role = "available"
      if name == config.source then
        role = "SOURCE"
      else
        for index, configuredName in ipairs(config.storages) do
          if name == configuredName then role = "STORAGE #" .. index end
        end
      end
      print(("  %-28s %-20s %s"):format(name, role, info.types))
    elseif peripheral.isPresent(name) and reason ~= "未接続です" then
      -- Do not treat monitors, modems or computers as errors.  Show only
      -- peripherals which look close to an inventory but lack one method.
      local methodsOk, methods = pcall(peripheral.getMethods, name)
      methods = methodsOk and methods or {}
      if hasMethod(methods, "list") or hasMethod(methods, "pushItems") then
        print(("  %-28s unavailable: %s"):format(name, reason))
      end
    end
  end
  if discovered == 0 then print("  (none)") end

  print("")
  print("Configured:")
  print("  SOURCE: " .. (configured(config.source) and config.source or "(not set)"))
  if #config.storages == 0 then
    print("  STORAGE: (none)")
  else
    for index, name in ipairs(config.storages) do
      print(("  STORAGE #%d: %s"):format(index, name))
    end
  end
  if loadWarning then print("Warning: " .. loadWarning) end
end

local function cmdSetSource(name)
  if not configured(name) then
    print("Error: storage set-source requires a peripheral name")
    return false
  end
  local info, reason = inventoryInfo(name)
  if not info then
    print("Error: SOURCE is not an inventory: " .. reason)
    return false
  end
  if not info.canPush then
    print("Error: SOURCE must provide pushItems()")
    return false
  end

  local oldSource = config.source
  local oldStorages = {}
  for index, value in ipairs(config.storages) do oldStorages[index] = value end
  config.source = name
  removeStorage(name)
  local saved, saveReason = saveConfig()
  if not saved then
    config.source = oldSource
    config.storages = oldStorages
    print("Error: " .. saveReason)
    return false
  end
  print("SOURCE set to " .. name)
  print("The SOURCE was removed from STORAGE if it was registered there.")
  return true
end

local function cmdAddStorage(name)
  if not configured(name) then
    print("Error: storage add requires a peripheral name")
    return false
  end
  if name == config.source then
    print("Error: SOURCE cannot also be STORAGE")
    return false
  end
  local info, reason = inventoryInfo(name)
  if not info then
    print("Error: STORAGE is not an inventory: " .. reason)
    return false
  end
  for _, configuredName in ipairs(config.storages) do
    if configuredName == name then
      print("Already registered as STORAGE: " .. name)
      return true
    end
  end

  config.storages[#config.storages + 1] = name
  local saved, saveReason = saveConfig()
  if not saved then
    table.remove(config.storages)
    print("Error: " .. saveReason)
    return false
  end
  print(("STORAGE #%d added: %s"):format(#config.storages, name))
  return true
end

local function cmdRemoveStorage(name)
  if not configured(name) then
    print("Error: storage remove requires a peripheral name")
    return false
  end
  local oldStorages = {}
  for index, value in ipairs(config.storages) do oldStorages[index] = value end
  if not removeStorage(name) then
    print("Not registered as STORAGE: " .. name)
    return false
  end
  local saved, saveReason = saveConfig()
  if not saved then
    config.storages = oldStorages
    print("Error: " .. saveReason)
    return false
  end
  print("STORAGE removed: " .. name)
  return true
end

local function printInventoryStatus(label, info)
  if not info then
    print(label .. ": unavailable")
    return
  end
  local size, sizeReason = readSize(info)
  local items, listReason = readList(info)
  if not size or not items then
    print(label .. ": unavailable (" .. text(sizeReason or listReason) .. ")")
    return
  end
  local total, usedSlots = itemCount(items)
  print(("%s: %d/%d slots, %d items"):format(label, usedSlots, size, total))
end

local function cmdStatus()
  print("Storage controller status")
  print("SOURCE: " .. (configured(config.source) and config.source or "(not set)"))
  print("STORAGE count: " .. #config.storages)

  if configured(config.source) then
    local source, reason = inventoryInfo(config.source)
    if source then
      printInventoryStatus("SOURCE", source)
    else
      print("SOURCE: unavailable (" .. text(reason) .. ")")
    end
  end

  for index, name in ipairs(config.storages) do
    local info, reason = inventoryInfo(name)
    if info then
      printInventoryStatus("STORAGE #" .. index .. " " .. name, info)
    else
      print(("STORAGE #%d %s: unavailable (%s)"):format(index, name, text(reason)))
    end
  end
  if loadWarning then print("Warning: " .. loadWarning) end
end

-- Push to one explicit destination slot and verify both sides afterwards.
-- This avoids trusting a guessed quantity when a peripheral is detached or
-- a destination becomes full between list() and pushItems().
local function verifiedPush(source, destination, sourceSlot, expectedItem,
  expectedCount, limit, destinationSlot)
  local beforeSource, sourceReason = readList(source)
  if not beforeSource then return nil, sourceReason end
  local sourceItem = beforeSource[sourceSlot]
  if not sameStack(sourceItem, expectedItem) then
    return nil, "SOURCE slot changed during transfer"
  end
  if sourceItem.count ~= expectedCount then
    return nil, "SOURCE quantity changed during transfer"
  end

  local beforeDestination, destinationReason = readList(destination)
  if not beforeDestination then return nil, destinationReason end
  local destinationItem = beforeDestination[destinationSlot]
  if destinationItem and not sameStack(destinationItem, expectedItem) then
    return nil, "destination slot changed to a different item"
  end

  local called, reported = pcall(source.object.pushItems, destination.name,
    sourceSlot, limit, destinationSlot)
  if not called then return nil, "pushItems() failed: " .. text(reported) end
  if type(reported) ~= "number" or reported < 0 then
    return nil, "pushItems() returned an invalid quantity"
  end

  local afterSource, afterSourceReason = readList(source)
  if not afterSource then return nil, afterSourceReason end
  local afterDestination, afterDestinationReason = readList(destination)
  if not afterDestination then return nil, afterDestinationReason end

  local afterSourceItem = afterSource[sourceSlot]
  if afterSourceItem and not sameStack(afterSourceItem, expectedItem) then
    return nil, "SOURCE slot changed to a different item"
  end
  local sourceAfterCount = afterSourceItem and afterSourceItem.count or 0
  local sourceMoved = sourceItem.count - sourceAfterCount

  local destinationAfterItem = afterDestination[destinationSlot]
  if not destinationAfterItem then
    if sourceMoved ~= 0 then
      return nil, "destination verification failed after items moved"
    end
    return 0
  end
  if not sameStack(destinationAfterItem, expectedItem) then
    return nil, "destination verification found a different item"
  end
  local destinationBeforeCount = destinationItem and destinationItem.count or 0
  local destinationMoved = destinationAfterItem.count - destinationBeforeCount

  if sourceMoved < 0 or sourceMoved > limit or destinationMoved < 0
    or sourceMoved ~= destinationMoved or sourceMoved ~= reported then
    return nil, ("transfer verification failed (reported=%s source=%s destination=%s)")
      :format(text(reported), text(sourceMoved), text(destinationMoved))
  end
  return sourceMoved
end

local function destinationCandidates(destination, item)
  local matching, empty = {}, {}
  for slot = 1, destination.size do
    local existing = destination.items[slot]
    if existing and sameStack(existing, item) then
      if not destination.blocked[slot] then matching[#matching + 1] = slot end
    elseif not existing and not destination.blocked[slot] then
      empty[#empty + 1] = slot
    end
  end
  for _, slot in ipairs(empty) do matching[#matching + 1] = slot end
  return matching
end

local function updateDestinationSnapshot(destination, slot, item, moved)
  local existing = destination.items[slot]
  if existing then
    existing.count = existing.count + moved
  else
    local newItem = copyItem(item)
    newItem.count = moved
    destination.items[slot] = newItem
  end
end

local function refreshConnections(context)
  context.source = nil
  context.destinations = {}
  context.missing = {}

  if configured(config.source) then
    local source, reason = inventoryInfo(config.source)
    if source and source.canPush then
      context.source = source
    else
      context.sourceReason = source and "SOURCE has no pushItems()" or reason
    end
  else
    context.sourceReason = "SOURCE is not configured"
  end

  for _, name in ipairs(config.storages) do
    if name ~= config.source then
      local info, reason = inventoryInfo(name)
      if info then
        context.destinations[#context.destinations + 1] = info
      else
        context.missing[#context.missing + 1] = name .. " (" .. text(reason) .. ")"
      end
    end
  end
  context.connectedStorageCount = #context.destinations
  context.configuredStorageCount = #config.storages
end

local function runCycle(context)
  if not context.source then
    return true, context.sourceReason or "SOURCE is unavailable"
  end
  if #context.destinations == 0 then
    return true, "No connected STORAGE is available"
  end

  local sourceItems, sourceReason = readList(context.source)
  if not sourceItems then return false, "SOURCE: " .. sourceReason end
  local sourceSlots = sortedItemSlots(sourceItems)
  if #sourceSlots == 0 then
    context.currentSourceItems = 0
    context.currentSourceSlots = 0
    return true
  end

  local destinations = {}
  for _, info in ipairs(context.destinations) do
    local items, listReason = readList(info)
    local size, sizeReason = readSize(info)
    if items and size then
      destinations[#destinations + 1] = {
        name = info.name,
        info = info,
        items = items,
        size = size,
        blocked = {},
      }
    else
      context.lastError = (info.name .. ": " .. text(listReason or sizeReason))
    end
  end
  if #destinations == 0 then
    return true, "No STORAGE inventory can be read"
  end

  local cycleMoved = 0
  local pushes = 0
  local limited = false
  local remainingDescriptions = {}

  for _, sourceSlot in ipairs(sourceSlots) do
    local sourceItem = sourceItems[sourceSlot]
    local remaining = sourceItem.count
    for _, destination in ipairs(destinations) do
      if remaining <= 0 or limited then break end
      local candidates = destinationCandidates(destination, sourceItem)
      for _, destinationSlot in ipairs(candidates) do
        if remaining <= 0 then break end
        if pushes >= MAX_PUSHES_PER_CYCLE then
          limited = true
          break
        end

        local moved, transferReason = verifiedPush(context.source, destination.info,
          sourceSlot, sourceItem, remaining, remaining, destinationSlot)
        pushes = pushes + 1
        if not moved then
          return false, destination.name .. ": " .. text(transferReason)
        end
        if moved > 0 then
          remaining = remaining - moved
          cycleMoved = cycleMoved + moved
          context.totalTransferred = context.totalTransferred + moved
          updateDestinationSnapshot(destination, destinationSlot, sourceItem, moved)
        else
          destination.blocked[destinationSlot] = true
        end
      end
    end
    sourceItem.count = remaining
    if remaining > 0 then
      remainingDescriptions[#remainingDescriptions + 1] = sourceItem.name .. " x" .. remaining
    end
  end

  context.lastCycleMoved = cycleMoved
  local afterSource = readList(context.source)
  if afterSource then
    context.currentSourceItems, context.currentSourceSlots = itemCount(afterSource)
  else
    context.currentSourceItems, context.currentSourceSlots = itemCount(sourceItems)
  end

  if #remainingDescriptions > 0 then
    local reason = "STORAGE full/unavailable: " .. table.concat(remainingDescriptions, ", ")
    if limited then reason = "cycle limit reached; " .. reason end
    return true, reason
  end
  if limited then return true, "cycle limit reached; continuing next cycle" end
  if cycleMoved > 0 then return true end
  return true, "No item could be transferred"
end

local function terminalWidth()
  local width = select(1, term.getSize())
  return type(width) == "number" and width or 51
end

local function terminalLine(value)
  local width = terminalWidth()
  local line = text(value)
  term.write(line:sub(1, width))
  if #line < width then term.write(string.rep(" ", width - #line)) end
  term.setCursorPos(1, select(2, term.getCursorPos()) + 1)
end

local function drawRunStatus(context, force)
  local signature = table.concat({
    config.source,
    context.connectedStorageCount or 0,
    context.configuredStorageCount or 0,
    context.currentSourceItems or 0,
    context.currentSourceSlots or 0,
    context.totalTransferred or 0,
    context.lastCycleMoved or 0,
    context.lastError or "",
    table.concat(context.missing or {}, ","),
  }, "|")
  if not force and context.drawSignature == signature then return end
  context.drawSignature = signature
  term.clear()
  term.setCursorPos(1, 1)
  terminalLine("WIRED STORAGE EXPORT CONTROLLER")
  terminalLine("SOURCE: " .. (config.source ~= "" and config.source or "(not set)"))
  terminalLine(("STORAGE: %d connected / %d configured"):format(
    context.connectedStorageCount or 0, context.configuredStorageCount or 0))
  terminalLine(("SOURCE ITEMS: %d in %d slots"):format(
    context.currentSourceItems or 0, context.currentSourceSlots or 0))
  terminalLine(("TRANSFERRED: %d items total"):format(context.totalTransferred or 0))
  terminalLine(("LAST CYCLE: %d items"):format(context.lastCycleMoved or 0))
  terminalLine("ERROR: " .. (context.lastError or "none"))
  if context.missing and #context.missing > 0 then
    terminalLine("MISSING: " .. table.concat(context.missing, ", "))
  end
  terminalLine("")
  terminalLine("Polling every " .. tostring(POLL_SECONDS) .. " seconds")
  terminalLine("Ctrl+T to stop")
end

local function runController()
  if not configured(config.source) then
    print("Error: configure SOURCE first with storage set-source <peripheral>")
    return false
  end
  if #config.storages == 0 then
    print("Error: add at least one STORAGE with storage add <peripheral>")
    return false
  end

  local context = {
    source = nil,
    destinations = {},
    missing = {},
    totalTransferred = 0,
    lastCycleMoved = 0,
    currentSourceItems = 0,
    currentSourceSlots = 0,
    lastError = nil,
  }

  refreshConnections(context)
  drawRunStatus(context, true)
  local ok, reason = runCycle(context)
  context.lastError = ok and reason or reason
  drawRunStatus(context)
  local timer = os.startTimer(POLL_SECONDS)

  while true do
    local event, value = os.pullEventRaw()
    if event == "terminate" then
      term.clear()
      term.setCursorPos(1, 1)
      print("Storage controller stopped.")
      return true
    elseif event == "peripheral" or event == "peripheral_detach" then
      refreshConnections(context)
      drawRunStatus(context, true)
    elseif event == "timer" and value == timer then
      refreshConnections(context)
      local cycleOk, cycleReason = runCycle(context)
      context.lastError = cycleReason
      if not cycleOk then
        -- Stop transferring for this cycle.  The source item remains in its
        -- inventory, and the next timer retries after the network settles.
        context.lastError = "SAFE STOP: " .. text(cycleReason)
      end
      drawRunStatus(context)
      timer = os.startTimer(POLL_SECONDS)
    end
  end
end

loadConfig()

local command = args[1]
if command == "list" then
  cmdList()
elseif command == "set-source" then
  cmdSetSource(args[2])
elseif command == "add" then
  cmdAddStorage(args[2])
elseif command == "remove" then
  cmdRemoveStorage(args[2])
elseif command == "status" then
  cmdStatus()
elseif command == "run" then
  runController()
elseif command == "help" or command == nil then
  usage()
else
  print("Unknown command: " .. text(command))
  usage()
end
