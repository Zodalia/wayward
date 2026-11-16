local _, ns = ...

-- Two questions for features not built yet:
--   controller support: does this client have the gamepad API, can an addon's
--     frame receive pad buttons, and does the game navigate its own windows?
--   journey sync: can addons send each other messages (party, whisper,
--     Battle.net), how long and how fast, and when is it locked down?
-- Static probes run with /wfprobe; /wfprobe pad and /wfprobe comms test live.

local try, get, probe = ns.try, ns.get, ns.probe

local function now()
  return type(GetTime) == "function" and GetTime() or 0
end

local function sortedNames(list, cap)
  table.sort(list)
  local total = #list
  while cap and #list > cap do table.remove(list) end
  return { count = total, names = table.concat(list, ", ") }
end

-- Globals (functions and tables) whose name holds one of `words`.
local function globalsNamed(words, cap)
  local hits = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and (type(v) == "function" or type(v) == "table") then
      local lk = k:lower()
      for _, word in ipairs(words) do
        if lk:find(word, 1, true) then hits[#hits + 1] = k .. ":" .. type(v) break end
      end
    end
  end
  return sortedNames(hits, cap)
end

-- C_ namespaces whose name holds one of `words`, each with its functions.
local function namespacesNamed(words)
  local out = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and k:find("^C_") and type(v) == "table" then
      local lk = k:lower()
      for _, word in ipairs(words) do
        if lk:find(word, 1, true) then out[k] = ns.listFunctions(k) break end
      end
    end
  end
  return out
end

local function cvarsNamed(words, cap)
  local getAll = (C_Console and C_Console.GetAllCommands) or ConsoleGetAllCommands
  if type(getAll) ~= "function" then return "unavailable" end
  local ok, commands = pcall(getAll)
  if not ok or type(commands) ~= "table" then return "unavailable" end
  local values, n = {}, 0
  for _, c in ipairs(commands) do
    local name = type(c) == "table" and c.command
    local lname = type(name) == "string" and name:lower() or ""
    for _, word in ipairs(words) do
      if lname:find(word, 1, true) then
        if n < cap then
          local v = get("C_CVar.GetCVar", name)
          values[name] = v == nil and "<no value>" or v
        end
        n = n + 1
        break
      end
    end
  end
  values._matched = n
  return values
end

---------------------------------------------------------------- gamepad

local PAD_SCRIPTS = { "OnGamePadButtonDown", "OnGamePadButtonUp", "OnGamePadStick", "OnKeyDown" }
local PAD_METHODS = { "EnableGamePadButton", "EnableGamePadStick", "EnableKeyboard", "SetPropagateKeyboardInput",
  "IsGamePadButtonEnabled", "IsGamePadStickEnabled" }
local PAD_KEYS = { "PAD1", "PAD2", "PAD3", "PAD4", "PADDUP", "PADDDOWN", "PADDLEFT", "PADDRIGHT",
  "PADLSHOULDER", "PADRSHOULDER", "PADLTRIGGER", "PADRTRIGGER", "PADLSTICK", "PADRSTICK", "PADFORWARD", "PADBACK" }

-- What a plain addon frame can do with a controller.
local function frameSupport()
  local f = CreateFrame("Frame")
  local scripts, methods = {}, {}
  for _, name in ipairs(PAD_SCRIPTS) do
    local ok, has = pcall(function() return f:HasScript(name) end)
    if ok then scripts[name] = has and true or false else scripts[name] = "error" end
  end
  for _, name in ipairs(PAD_METHODS) do
    methods[name] = type(f[name]) == "function"
  end
  return { scripts = scripts, methods = methods }
end

probe("input", "gamepad", function()
  local hasAPI = type(C_GamePad) == "table"
  local enabled = try("C_GamePad.IsEnabled")
  ns.headline("gamepadAPI", hasAPI)
  ns.headline("gamepadEnabled", enabled.status == "ok" and enabled.value or enabled.status)
  local bindings = {}
  for _, key in ipairs(PAD_KEYS) do
    local action = get("GetBindingAction", key)
    if action ~= nil and action ~= "" then bindings[key] = action end
  end
  return {
    functions = ns.listFunctions("C_GamePad"),
    reads = hasAPI and ns.explore("C_GamePad", { a_none = {} }) or "<missing>",
    isEnabled = enabled,
    frames = frameSupport(),
    bindings = bindings,
    cvars = cvarsNamed({ "gamepad", "controller" }, 60),
    -- The game's own way of moving through windows with a controller, if it
    -- has one: an addon would rather join that than build its own.
    globals = globalsNamed({ "gamepad", "controller", "consoleport" }, 80),
    namespaces = namespacesNamed({ "pad", "controller", "cursor", "focus", "input", "keybind" }),
    enums = (function()
      local out = {}
      for k in pairs(Enum or {}) do
        local lk = tostring(k):lower()
        if lk:find("gamepad", 1, true) or lk:find("controller", 1, true) then out[k] = Enum[k] end
      end
      return out
    end)(),
  }
end)

-- Forever moves a cursor between the buttons of its own windows ("Smart
-- Navigation"). Can an addon's window join in? Everything that names it: the
-- globals, what its mixins and frames can do, the methods every frame has for
-- it, its settings and events, and the newer key binding contexts.
local NAV_WORDS = { "smartnav", "inputlegend", "inputinterface", "focusstate", "gamepadnav", "gamepadui", "gamepadfocus" }
local NAV_METHOD_WORDS = { "nav", "gamepad", "focus", "inputlegend" }
local NAV_EVENTS = { "GAME_PAD_ACTIVE_CHANGED", "GAME_PAD_CONNECTED", "GAME_PAD_DISCONNECTED", "GAME_PAD_CONFIGS_CHANGED",
  "GAME_PAD_POWER_CHANGED", "INPUT_INTERFACE_STYLE_CHANGED", "SMART_NAVIGATION_CURSOR_CHANGED",
  "SMART_NAVIGATION_FOCUS_CHANGED", "SMART_NAVIGATION_STATE_CHANGED", "GAMEPAD_UI_STATE_CHANGED",
  "BINDING_CONTEXT_CHANGED", "UPDATE_BINDINGS" }
local MAX_NAV_TABLES, MAX_METHODS = 40, 80

local function functionNames(t, cap)
  local names = {}
  for k, v in pairs(t) do
    if type(k) == "string" and type(v) == "function" then names[#names + 1] = k end
  end
  return sortedNames(names, cap).names
end

local function matches(name, words)
  local lname = name:lower()
  for _, word in ipairs(words) do
    if lname:find(word, 1, true) then return true end
  end
  return false
end

-- The methods a widget type has whose names touch navigation.
local widgetCache = {}

local function widgetMethods(frameType)
  local f = widgetCache[frameType]
  if not f then
    local ok, made = pcall(CreateFrame, frameType)
    if not ok or not made then return "can't create" end
    f = made
    widgetCache[frameType] = f
    -- A new EditBox takes keyboard focus the moment it exists, and an
    -- invisible one never gives it back: every key goes into it.
    pcall(function() f:SetAutoFocus(false) end)
    pcall(function() f:ClearFocus() end)
    pcall(function() f:EnableKeyboard(false) end)
    pcall(function() f:Hide() end)
  end
  local mt = getmetatable(f)
  local index = type(mt) == "table" and mt.__index
  if type(index) ~= "table" then return "no method table" end
  local names = {}
  for k, v in pairs(index) do
    if type(k) == "string" and type(v) == "function" and matches(k, NAV_METHOD_WORDS) then names[#names + 1] = k end
  end
  return sortedNames(names, MAX_METHODS).names
end

probe("input", "smartNavigation", function()
  -- Mixins and other tables named for it, each with what it can do; frames
  -- with their type and whether they're showing.
  local names = {}
  for k, v in pairs(_G) do
    if type(k) == "string" and type(v) == "table" and matches(k, NAV_WORDS) then names[#names + 1] = k end
  end
  table.sort(names)
  local tables = {}
  for i = 1, math.min(#names, MAX_NAV_TABLES) do
    local t = _G[names[i]]
    local entry = { functions = functionNames(t, MAX_METHODS) }
    if type(rawget(t, 0)) == "userdata" and type(t.GetObjectType) == "function" then
      local ok, kind = pcall(t.GetObjectType, t)
      entry.frame = ok and kind or "?"
      local shownOk, shown = pcall(t.IsShown, t)
      entry.shown = shownOk and shown or nil
    end
    tables[names[i]] = entry
  end

  local events, f = {}, CreateFrame("Frame")
  for _, event in ipairs(NAV_EVENTS) do
    events[event] = pcall(f.RegisterEvent, f, event) and true or false
  end
  pcall(function() f:UnregisterAllEvents() end)

  local enums = {}
  for k in pairs(Enum or {}) do
    local name = tostring(k)
    if not name:find("Meta$") and matches(name, { "smartnav", "inputinterface", "inputstyle", "bindingcontext", "inputlegend" }) then
      enums[name] = Enum[k]
    end
  end

  local style = try("C_InputInterfaceStyle.GetCurrentStyle")
  ns.headline("smartNavigationTables", #names)
  ns.headline("inputStyle", style.status == "ok" and style.value or style.status)
  return {
    tableCount = #names,
    tables = tables,
    functions = globalsNamed(NAV_WORDS, 200),
    widgetMethods = { Frame = widgetMethods("Frame"), Button = widgetMethods("Button"),
      EditBox = widgetMethods("EditBox"), ScrollFrame = widgetMethods("ScrollFrame") },
    inputStyle = style,
    events = events,
    enums = enums,
    cvars = cvarsNamed({ "smartnav", "inputlegend", "interfacestyle", "inputstyle" }, 40),
    gamepadUI = type(C_GamepadUI) == "table" and ns.explore("C_GamepadUI", { a_none = {} }) or "<missing>",
    keyBindings = {
      functions = ns.listFunctions("C_KeyBindings"),
      reads = type(C_KeyBindings) == "table" and ns.explore("C_KeyBindings", { a_none = {}, b_pad1 = { "PAD1" },
        c_context0 = { 0 }, d_context1 = { 1 } }) or "<missing>",
    },
  }
end)

-- /wfprobe pad: a frame of ours listens for controller buttons and sticks for
-- a few seconds. While it listens it takes the buttons, as a Wayward window
-- with the controller's focus would.
local PAD_SECONDS = 10
local padFrame, padRun

local function padStore(result)
  local data = ns.charData()
  data.probes = data.probes or {}
  data.probes.input = data.probes.input or {}
  data.probes.input.padCapture = { status = "ok", value = result }
  ns.RefreshExportIfShown()
end

function ns.ProbePad()
  if padRun then
    ns.print("already listening; press some controller buttons.")
    return
  end
  local result = {
    at = date("%Y-%m-%d %H:%M:%S"), inCombat = InCombatLockdown(), seconds = PAD_SECONDS,
    isEnabled = try("C_GamePad.IsEnabled"), activeDevice = try("C_GamePad.GetActiveDeviceID"),
    buttons = {}, sticks = {}, setup = {},
  }
  padFrame = padFrame or CreateFrame("Frame", "WFProbePadCatcher", UIParent)
  local f = padFrame
  local function step(name, fn)
    local ok, err = pcall(fn)
    result.setup[name] = ok and "ok" or ("error: " .. tostring(err))
    return ok
  end
  step("place", function()
    f:SetSize(1, 1)
    f:SetPoint("CENTER")
    f:Show()
  end)
  local listening = step("OnGamePadButtonDown", function()
    f:SetScript("OnGamePadButtonDown", function(_, button)
      button = tostring(button)
      result.buttons[button] = (result.buttons[button] or 0) + 1
    end)
  end)
  step("OnGamePadStick", function()
    f:SetScript("OnGamePadStick", function(_, stick)
      stick = tostring(stick)
      result.sticks[stick] = (result.sticks[stick] or 0) + 1
    end)
  end)
  step("EnableGamePadButton", function() f:EnableGamePadButton(true) end)
  step("EnableGamePadStick", function() f:EnableGamePadStick(true) end)
  if not listening then
    result.verdict = "this client's frames have no OnGamePadButtonDown script"
    padStore(result)
    ns.print("frames can't listen for controller buttons here (see /wfprobe show, input.padCapture).")
    return
  end
  padRun = result
  ns.print(string.format("listening for %d seconds: press controller buttons and move both sticks.", PAD_SECONDS))
  C_Timer.After(PAD_SECONDS, function()
    padRun = nil
    pcall(function() f:EnableGamePadButton(false) end)
    pcall(function() f:EnableGamePadStick(false) end)
    pcall(function() f:SetScript("OnGamePadButtonDown", nil) end)
    pcall(function() f:SetScript("OnGamePadStick", nil) end)
    pcall(function() f:Hide() end)
    local names = {}
    for button in pairs(result.buttons) do names[#names + 1] = button end
    table.sort(names)
    result.verdict = #names > 0 and "an addon frame received controller buttons" or "no buttons reached the frame"
    padStore(result)
    ns.print(#names > 0 and ("buttons seen: " .. table.concat(names, ", ") .. ".")
      or "no controller buttons reached the frame (controller off, or the client keeps them).")
  end)
end

---------------------------------------------------------------- addon messages

local PREFIX = "WFProbe"

local function sendFunction()
  if C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" then return "C_ChatInfo.SendAddonMessage" end
  if type(SendAddonMessage) == "function" then return "SendAddonMessage" end
  return nil
end

local function groupState()
  return {
    inGroup = get("IsInGroup"), inRaid = get("IsInRaid"), members = get("GetNumGroupMembers"),
    inInstance = try("IsInInstance"),
  }
end

-- Registering a prefix answers in its own codes, not the send's.
local function describeRegister(rec)
  if rec.status ~= "ok" then return rec.status end
  local v = rec.values and rec.values[1] or rec.value
  local enum = Enum and Enum.RegisterAddonMessagePrefixResult
  return type(v) == "number" and (enum and ns.enumName(enum, v) or ("code " .. v)) or tostring(v)
end

probe("comms", "addonMessages", function()
  local send = sendFunction()
  ns.headline("addonMessages", send or false)
  ns.headline("battleNetGameData", type(BNSendGameData) == "function")
  return {
    send = send or "<missing>",
    chatInfo = ns.listFunctions("C_ChatInfo"),
    resultEnum = Enum and Enum.SendAddonMessageResult or "<no Enum.SendAddonMessageResult>",
    registerPrefix = describeRegister(try("C_ChatInfo.RegisterAddonMessagePrefix", PREFIX)),
    registerEnum = Enum and Enum.RegisterAddonMessagePrefixResult or "<no Enum.RegisterAddonMessagePrefixResult>",
    outgoingRestricted = try("C_ChatInfo.AreOutgoingAddonChatMessagesRestricted"),
    addOnRestriction = type(C_RestrictedActions) == "table" and ns.explore("C_RestrictedActions", { a_none = {} }) or "<missing>",
    prefixRegistered = try("C_ChatInfo.IsAddonMessagePrefixRegistered", PREFIX),
    -- 12.x locks addon messages in some instanced content.
    messagingLockdown = try("C_ChatInfo.InChatMessagingLockdown"),
    restrictions = namespacesNamed({ "restrict", "secret", "lockdown" }),
    battleNet = {
      sendGameData = type(BNSendGameData),
      connected = try("BNConnected"),
      numFriends = try("BNGetNumFriends"),
      functions = ns.listFunctions("C_BattleNet"),
    },
    group = groupState(),
    partyInfo = ns.listFunctions("C_PartyInfo"),
    friendList = ns.listFunctions("C_FriendList"),
  }
end)

-- The client's own packing of tables into text (C_EncodingUtil in 11.1.5 and
-- later): whether a journey can be serialised, squeezed and made safe for a
-- message without code of ours, and how small it gets.
probe("comms", "encoding", function()
  local out = { functions = ns.listFunctions("C_EncodingUtil"), enums = {} }
  for k in pairs(Enum or {}) do
    local name = tostring(k)
    if not name:find("Meta$") and matches(name, { "compress", "base64", "serializ", "encoding" }) then
      out.enums[name] = Enum[k]
    end
  end
  ns.headline("encodingUtil", type(C_EncodingUtil) == "table")
  if type(C_EncodingUtil) ~= "table" then return out end

  -- About what a short journey would send: a title and a dozen stops.
  local sample = { v = 1, title = "The Perfect Stout", stops = {} }
  for i = 1, 12 do
    sample.stops[i] = { q = 1000 + i, k = i % 3 == 0 and "turnin" or "complete", m = 1426, x = 0.4321, y = 0.5678, done = i < 4 }
  end
  local function size(rec)
    local v = rec.values and rec.values[1] or rec.value
    return rec.status == "ok" and type(v) == "string" and #v or rec.status .. (rec.err and (": " .. rec.err) or ""), v
  end
  local function chain(label, serialise, deserialise)
    local step = {}
    out[label] = step
    local packed, compressed, encoded
    step.serialised, packed = size(try("C_EncodingUtil." .. serialise, sample))
    if type(packed) ~= "string" then return step end
    step.compressed, compressed = size(try("C_EncodingUtil.CompressString", packed))
    local body = type(compressed) == "string" and compressed or packed
    step.base64, encoded = size(try("C_EncodingUtil.EncodeBase64", body))
    -- And back again.
    if type(encoded) == "string" then
      local decoded = get("C_EncodingUtil.DecodeBase64", encoded)
      local plain = decoded
      if type(compressed) == "string" then plain = get("C_EncodingUtil.DecompressString", decoded) end
      local back = type(plain) == "string" and get("C_EncodingUtil." .. deserialise, plain) or nil
      step.roundTrip = type(back) == "table" and type(back.stops) == "table" and #back.stops == 12
        and back.stops[12].q == 1012 and back.title == sample.title
    end
    return step
  end
  chain("cbor", "SerializeCBOR", "DeserializeCBOR")
  chain("json", "SerializeJSON", "DeserializeJSON")
  return out
end)

-- /wfprobe comms [name]: sends test messages under our own prefix and records
-- what each send returned and which came back. First a ping to yourself by
-- whisper under every form of your name the client offers (Forever gives
-- players a second name, and which form a whisper wants isn't known), and to
-- the party or raid when you're in one; then, over whichever of those came
-- back, the length limit and the throttle. `name` adds a form to try.
local PING_WAIT = 2
local COMMS_WAIT = 5
local BURST = 15
local SIZES = { 255, 256, 1024 }
local commsFrame, commsRun

local function describeSend(rec)
  if rec.status ~= "ok" and rec.status ~= "empty" then return rec.status .. (rec.err and (": " .. rec.err) or "") end
  local values = rec.values or { rec.value }
  local parts = {}
  for i = 1, #values do
    local v = values[i]
    parts[i] = type(v) == "number" and Enum and Enum.SendAddonMessageResult
      and ns.enumName(Enum.SendAddonMessageResult, v) or tostring(v)
  end
  return #parts > 0 and table.concat(parts, ", ") or "nil"
end

-- Every byte a message might carry but 0, which ends a string in the client.
local BINARY = (function()
  local bytes = {}
  for i = 1, 250 do bytes[i] = string.char(i) end
  return "bin:" .. table.concat(bytes)
end)()

-- The plain strings a call returned, in order.
local function strings(rec)
  local out = {}
  local values = rec.values or { rec.value }
  for i = 1, #values do
    local v = values[i]
    if type(v) == "string" and not ns.isSecret(v) and v ~= "" then out[#out + 1] = v end
  end
  return out
end

local NAME_CALLS = {
  { "UnitName", "player" }, { "UnitFullName", "player" }, { "UnitNameUnmodified", "player" },
  { "GetUnitName", "player", true }, { "GetUnitName", "player", false }, { "UnitPVPName", "player" },
  { "GetNormalizedRealmName" }, { "GetRealmName" },
}
local unpack = unpack or table.unpack

-- What the client calls you, by each function that names a player, and the
-- forms of it a whisper might take.
local function playerNames(extra)
  local facts, candidates, seen = {}, {}, {}
  local function add(name)
    if type(name) == "string" and name ~= "" and not seen[name] and #candidates < 12 then
      seen[name] = true
      candidates[#candidates + 1] = name
    end
  end
  add(extra)
  for i, call in ipairs(NAME_CALLS) do
    local rec = try(unpack(call))
    local label = call[1] .. (call[3] ~= nil and ("(" .. tostring(call[3]) .. ")") or "")
    local got = strings(rec)
    facts[label] = rec.status == "ok" and (#got > 0 and table.concat(got, " | ") or "<no strings>") or rec.status
    if i <= 5 then
      add(got[1])
      -- A second return is the realm in other clients; here it may be the second name.
      if got[2] then add(got[1] .. " " .. got[2]) add(got[1] .. "-" .. got[2]) end
      if got[3] then add(got[1] .. " " .. got[2] .. "-" .. got[3]) end
    end
  end
  local realm = get("GetNormalizedRealmName")
  if type(realm) == "string" and realm ~= "" then
    for i = 1, #candidates do
      if not candidates[i]:find("-", 1, true) then add(candidates[i] .. "-" .. realm) end
    end
  end
  facts.functionsNamed = globalsNamed({ "surname", "lastname", "familyname", "secondname", "fullname" }, 40)
  return facts, candidates
end

function ns.ProbeComms(extraName)
  local path = sendFunction()
  if not path then
    ns.print("this client has no SendAddonMessage.")
    return
  end
  if commsRun then
    ns.print("a comms test is still waiting for replies.")
    return
  end
  local names, candidates = playerNames(extraName ~= "" and extraName or nil)
  local result = {
    at = date("%Y-%m-%d %H:%M:%S"), inCombat = InCombatLockdown(), send = path, group = groupState(),
    registerPrefix = describeRegister(try("C_ChatInfo.RegisterAddonMessagePrefix", PREFIX)),
    messagingLockdown = try("C_ChatInfo.InChatMessagingLockdown"),
    outgoingRestricted = try("C_ChatInfo.AreOutgoingAddonChatMessagesRestricted"),
    names = names, sent = {}, received = {},
  }
  if not commsFrame then
    commsFrame = CreateFrame("Frame")
    result.event = pcall(commsFrame.RegisterEvent, commsFrame, "CHAT_MSG_ADDON") and "registered" or "unknown event"
    commsFrame:SetScript("OnEvent", function(_, _, prefix, text, channel, sender)
      if prefix ~= PREFIX or not commsRun then return end
      local run = commsRun
      text = tostring(text)
      local whisper = tonumber(text:match("^ping:w(%d+)$"))
      if whisper then run.whisperWorked = run.whisperWorked or whisper end
      if text == "ping:party" then run.partyWorked = true end
      if text:sub(1, 4) == "bin:" then
        if text == BINARY then
          run.binary = "arrived intact: any byte but 0 can be sent as it is"
        else
          local at = 0
          for i = 1, #BINARY do
            if text:byte(i) ~= BINARY:byte(i) then at = i - 4 break end
          end
          run.binary = string.format("changed on the way: %d of %d bytes arrived, first difference at byte value %d", #text, #BINARY, at)
        end
        text = "bin:<" .. (#text - 4) .. " bytes>"
      end
      if #run.received < 40 then
        run.received[#run.received + 1] = { text = #text > 24 and (text:sub(1, 24) .. "... (" .. #text .. " bytes)") or text,
          channel = channel, sender = sender, after = string.format("%.2fs", now() - run.started) }
      end
      run.receivedCount = (run.receivedCount or 0) + 1
    end)
  end
  commsRun = result
  result.started = now()
  local total = 0

  local function send(label, text, channel, target)
    total = total + 1
    local outcome = describeSend(try(path, PREFIX, text, channel, target))
    if label then result.sent[#result.sent + 1] = label .. " -> " .. outcome end
    return outcome
  end
  for i, name in ipairs(candidates) do
    send(string.format("whisper %d to \"%s\"", i, name), "ping:w" .. i, "WHISPER", name)
  end
  if result.group.inGroup then send("party", "ping:party", "PARTY") end
  if result.group.inRaid then send("raid", "ping:raid", "RAID") end

  local function finish()
    commsRun = nil
    result.started, result.partyWorked = nil, nil
    result.receivedCount = result.receivedCount or 0
    local data = ns.charData()
    data.probes = data.probes or {}
    data.probes.comms = data.probes.comms or {}
    data.probes.comms.sendTest = { status = "ok", value = result }
    ns.print(string.format("%d of %d test messages came back (%s). /wfprobe show for the detail (comms.sendTest).",
      result.receivedCount, total, result.route or "no way through"))
    ns.RefreshExportIfShown()
  end

  ns.print(string.format("sent %d pings; checking which come back...", total))
  C_Timer.After(PING_WAIT, function()
    -- Length and throttle over a way that works.
    local channel, target
    if result.whisperWorked then
      channel, target = "WHISPER", candidates[result.whisperWorked]
      result.whisperName = target
      result.route = "whisper to \"" .. target .. "\""
    elseif result.partyWorked then
      channel = "PARTY"
      result.route = "party"
    else
      result.verdict = "no ping came back: none of the names reached you by whisper"
        .. (result.group.inGroup and ", and the party ping didn't either" or "; try again in a party, or /wfprobe comms <your name as others whisper it>")
      return finish()
    end
    -- The length limit (255 bytes in other clients).
    for _, size in ipairs(SIZES) do
      send(size .. " bytes", string.rep("x", size), channel, target)
    end
    -- Raw bytes, or does a message need its contents made into plain text first?
    result.binary = "never arrived"
    send("every byte 1-250", BINARY, channel, target)
    -- The throttle: how many in a row go out.
    local burst = {}
    for i = 1, BURST do burst[i] = send(nil, "burst:" .. i, channel, target) end
    result.burst = table.concat(burst, " | ")
    C_Timer.After(COMMS_WAIT, finish)
  end)
end
