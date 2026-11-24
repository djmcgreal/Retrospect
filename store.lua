-- The characters, in RetrospectDB.chars[GUID]. A character's sections each carry their own
-- `seen` (when Retrospect last read them): a section that is missing was never read, which is not
-- the same as empty. Sections:
--
--   name, full (first and last name), realm (if the game ever named it), class, race, faction, level, money, seen (last time on this character), zone, subzone,
--   guild, spec, ilvl, bind, played, xp, xpMax, rest, resting, goldDays = { [day] = copper }
--   bags, bank = { seen, slots, free, containers = { { id, size, free, name, items = packed } } }
--   gear = { seen, slots = { [slot] = packed entry } }
--   mail = { seen, list = { { from, subject, money, cod, expires, read, items = packed } } }
--   incoming = { { from, subject, money, arrives, items = packed } }   (mail your own alts sent)
--   auctions = { seen, list = { { item = packed, buyout, bid, expires, sold } }, bids = { same } }
--   quests = { seen, log = { { id, title, level, complete, done, need, objectives } }, done = packed ids, doneCount }
--   professions = { seen, skills = { [skillLine] = { rank, max, name, seen, source, count, recipes = packed ids } } }
--   reputation = { seen, list = { [factionId] = { reaction, value, low, high } } }
--   lockouts = { seen, list = { { name, reset, killed, total, raid } } }
--   cooldowns = { [spellId] = ready time }
--
-- Items are packed into one string per container ("id,count,quality,bound,itemstring;...", the item
-- string only when the item has an enchant or suffix), so a character costs a few kilobytes and the
-- saved file stays quick to load. Quest and recipe id lists are packed as base-36 differences.

local Core = NorgannonCore
local R = Retrospect
if R.disabled then return end

local Store = {}
R.Store = Store

local chars
local sorted
local myKey
local unpacked = {}   -- packed id lists of other characters, once asked for

function Store:Loaded()
  chars = R.db.chars
end

-------------------------------------------------------------------------------------------
-- Keys. Until 0.11.0 a character was kept under "Realm-Name". The game stopped naming the realm on 2026-11-20, so the
-- same character came back as "-Name", twice in every list. Now it's the GUID (Core.Character). Upgrade puts the two
-- copies together when the saved data loads; a character moves to its GUID when it next logs in.
-------------------------------------------------------------------------------------------

local Character = Core.Character
local SECTIONS = { "bags", "bank", "gear", "mail", "auctions", "quests", "reputation", "lockouts" }
-- where being missing means something: no guild any more, no spec chosen
local MAY_BE_GONE = { guild = true, spec = true }

-- one professions section from two, the newer on top
local function mergeProfessions(top, under)
  if not (top and under) then return top or under end
  if (under.seen or 0) > (top.seen or 0) then top, under = under, top end
  for skill, p in pairs(top.skills or {}) do
    local q = under.skills and under.skills[skill]
    -- recipes are only read with the profession open, so the older copy may be the only one that has them
    if q and q.recipes and (not p.recipes or (q.seen or 0) > (p.seen or 0)) then
      p.recipes, p.count, p.source, p.seen = q.recipes, q.count, q.source, q.seen
    end
  end
  return top
end

---One character from two copies of it: each section from the copy that read it last.
function Store.Merge(a, b)
  if not (a and b) then return a or b end
  local top, under = b, a
  if (a.seen or 0) > (b.seen or 0) then top, under = a, b end
  for _, s in ipairs(SECTIONS) do
    local x, y = top[s], under[s]
    if x and y then
      if (y.seen or 0) > (x.seen or 0) then x, y = y, x end
      if s == "quests" and not x.done then x.done, x.doneCount = y.done, y.doneCount end
      if s == "reputation" then
        x.list = x.list or {}
        for id, r in pairs(y.list or {}) do if x.list[id] == nil then x.list[id] = r end end
      end
      top[s] = x
    end
  end
  top.professions = mergeProfessions(top.professions, under.professions)
  for day, copper in pairs(under.goldDays or {}) do
    top.goldDays = top.goldDays or {}
    if top.goldDays[day] == nil then top.goldDays[day] = copper end
  end
  for spell, ready in pairs(under.cooldowns or {}) do
    top.cooldowns = top.cooldowns or {}
    top.cooldowns[spell] = math.max(top.cooldowns[spell] or 0, ready)
  end
  if top.incoming and under.incoming then
    for _, mail in ipairs(under.incoming) do top.incoming[#top.incoming + 1] = mail end
  end
  if top.played and under.played then top.played = math.max(top.played, under.played) end
  if (top.realm or "") == "" then top.realm = under.realm end
  for k, v in pairs(under) do
    if top[k] == nil and not MAY_BE_GONE[k] then top[k] = v end
  end
  return top
end

-- false for two copies that can't be one character: another class or race
local function sameCharacter(a, b)
  return (a.class == nil or b.class == nil or a.class == b.class) and (a.race == nil or b.race == nil or a.race == b.race)
end

---Saved data from before 0.11.0: a character, or a guild bank, kept both under a realm name and under none.
function Store.Upgrade(sv)
  if type(sv.chars) == "table" then
    for _, p in ipairs(Character.Pairs(sv.chars, { same = sameCharacter })) do
      sv.chars[p.to] = Store.Merge(sv.chars[p.to], sv.chars[p.from])
      sv.chars[p.from] = nil
      if sv.who == p.from then sv.who = p.to end
    end
  end
  if type(sv.guilds) == "table" then
    for _, p in ipairs(Character.Pairs(sv.guilds)) do
      if (sv.guilds[p.from].seen or 0) >= (sv.guilds[p.to].seen or 0) then sv.guilds[p.to] = sv.guilds[p.from] end
      sv.guilds[p.from] = nil
    end
  end
end

-- what the character logged in has under an old key moves to its GUID
local function adopt(key, name)
  local _, class = R.Global("UnitClass", "player")
  local level = R.Global("UnitLevel", "player")
  local from = Character.Mine(chars, name, { mine = function(c)
    return (class == nil or c.class == nil or c.class == class) and not (level and c.level and c.level > level)
  end })
  if not from then return end
  chars[key] = Store.Merge(chars[from], chars[key])
  chars[from] = nil
  sorted, unpacked = nil, {}
  if R.db.who == from then R.db.who = key end
  if R.Index then R.Index:Invalidate() end
end

---The key of the character logged in now: its GUID.
function Store:MyKey()
  if not myKey then
    local name = R.Global("UnitName", "player") or "Unknown"
    local key = Character.Key()
    -- before the game says who this is: an old-style key, which the GUID takes over once it's known
    if not key then return "-" .. name end
    if not chars then return key end
    myKey = key
    adopt(key, name)
  end
  return myKey
end

---The record of the character logged in now, created the first time it is seen.
function Store:Me()
  local key = self:MyKey()
  local c = chars[key]
  if not c then
    c = { name = R.Global("UnitName", "player") or "Unknown", goldDays = {} }
    chars[key] = c
    sorted = nil
  end
  return c
end

function Store:Get(key) return chars[key] end

---The server a character is on, for grouping: from its GUID. A character that hasn't logged in since 0.11.0 has only
---its old key, so it's with the others of its realm, or with you if that can't be told.
function Store:ServerOf(key, c)
  local server = Character.Server(key)
  if server then return server end
  if c and (c.realm or "") ~= "" then
    local named = false
    for k, other in pairs(chars) do
      local s = Character.Server(k)
      if s and other.realm == c.realm then return s end
      if s and (other.realm or "") ~= "" then named = true end
    end
    if named then return c.realm end   -- a realm nobody here is on
  end
  return Character.Server() or ""
end

---What to call a server: the realm name it had, if the game ever said.
function Store:ServerName(server)
  for k, c in pairs(chars) do
    if (c.realm or "") ~= "" and self:ServerOf(k, c) == server then return c.realm end
  end
end

---Every character as { key, c, server }: your server first; you, then higher levels first in each.
function Store:List()
  if sorted then return sorted end
  local here = self:ServerOf(self:MyKey())   -- first: this can move your record to its GUID
  sorted = {}
  for key, c in pairs(chars) do sorted[#sorted + 1] = { key = key, c = c, server = self:ServerOf(key, c) } end
  table.sort(sorted, function(a, b)
    local ar, br = a.server == here, b.server == here
    if ar ~= br then return ar end
    if a.server ~= b.server then return a.server < b.server end
    if a.key == myKey or b.key == myKey then return a.key == myKey end   -- who you're on, first
    if (a.c.level or 0) ~= (b.c.level or 0) then return (a.c.level or 0) > (b.c.level or 0) end
    return tostring(a.c.name) < tostring(b.c.name)
  end)
  return sorted
end

---Levels change sort order; called when this character's facts are read.
function Store:Resort() sorted = nil end

---Removes a character for good (Settings > Forget a character).
function Store:Forget(key)
  if key == self:MyKey() then return false end
  chars[key] = nil
  sorted = nil
  unpacked = {}
  R:Changed(key, true)
  return true
end

-------------------------------------------------------------------------------------------
-- Packed items
-------------------------------------------------------------------------------------------

local MEANINGFUL = "item:%d+:(%d*):%d*:%d*:%d*:%d*:(%-?%d*)"

---One packed entry. link is the item's hyperlink, when there is one; its item string is kept only
---when an enchant or suffix makes this copy different from the plain item.
function Store.Entry(id, count, quality, bound, link)
  local itemString = ""
  if type(link) == "string" then
    local enchant, suffix = link:match(MEANINGFUL)
    if (enchant and enchant ~= "" and enchant ~= "0") or (suffix and suffix ~= "" and suffix ~= "0") then
      itemString = link:match("(item:[%-%d:]+)") or ""
    end
    -- a name for items NorgannonDB doesn't have (Forever's own, say)
    if not Core.DB:Name("items", id) then
      local name = link:match("%[(.-)%]")
      if name and name ~= "" then R.db.names[id] = name end
    end
  end
  return string.format("%d,%d,%s,%s,%s", id, count or 1, quality and tostring(quality) or "", bound and "1" or "", itemString)
end

local ENTRY = "^(%d+),(%d+),(%d*),(%d*),?(.*)$"

---fn(id, count, quality, bound, itemString) for each item in a packed string.
function Store.EachItem(packed, fn)
  if not packed or packed == "" then return end
  for entry in packed:gmatch("[^;]+") do
    local id, count, q, bound, itemString = entry:match(ENTRY)
    if id then
      fn(tonumber(id), tonumber(count), tonumber(q), bound == "1", itemString ~= "" and itemString or nil)
    end
  end
end

---A packed string as a list of { id, count, q, bound, link }.
function Store.Items(packed)
  local out = {}
  Store.EachItem(packed, function(id, count, q, bound, link)
    out[#out + 1] = { id = id, count = count, q = q, bound = bound, link = link }
  end)
  return out
end

-------------------------------------------------------------------------------------------
-- Packed id lists: sorted, as base-36 differences
-------------------------------------------------------------------------------------------

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function base36(n)
  if n == 0 then return "0" end
  local out = {}
  while n > 0 do
    local d = n % 36
    out[#out + 1] = DIGITS:sub(d + 1, d + 1)
    n = math.floor(n / 36)
  end
  return string.reverse(table.concat(out))
end

---A set { [id] = true } as a compact string.
function Store.PackIds(set)
  local ids = {}
  for id in pairs(set) do ids[#ids + 1] = id end
  table.sort(ids)
  local out, last = {}, 0
  for i, id in ipairs(ids) do
    out[i] = base36(id - last)
    last = id
  end
  return table.concat(out, " "), #ids
end

---The compact string back as a set.
function Store.UnpackIds(packed)
  local set, last = {}, 0
  for piece in (packed or ""):gmatch("%S+") do
    last = last + tonumber(piece, 36)
    set[last] = true
  end
  return set
end

-------------------------------------------------------------------------------------------
-- Questions about a character. The one logged in answers from the live state; others unpack once.
-------------------------------------------------------------------------------------------

---A character's completed quests as a set. Returns nil if none were ever read.
local function doneSet(key)
  if key == Store:MyKey() and Core.Player.ready then return Core.Player.completed end
  local c = chars[key]
  local q = c and c.quests
  if not (q and q.done) then return nil end
  local set = unpacked[key]
  if not set then
    set = Store.UnpackIds(q.done)
    unpacked[key] = set
  end
  return set
end

---true / false, or nil when that character's quests were never read.
function Store:QuestDone(key, id)
  local set = doneSet(key)
  if not set then return nil end
  return set[id] == true
end

function Store:QuestDoneCount(key)
  if key == self:MyKey() and Core.Player.ready then
    local n = 0
    for _ in pairs(Core.Player.completed) do n = n + 1 end
    return n
  end
  local q = chars[key] and chars[key].quests
  return q and q.doneCount
end

---The quest-log entry for a quest on a character, or nil.
function Store:QuestInLog(key, id)
  local q = chars[key] and chars[key].quests
  for _, entry in ipairs(q and q.log or {}) do
    if entry.id == id then return entry end
  end
end

---The set of recipes a character knows in a profession, and the profession's record; nil set = not read.
function Store:Recipes(key, skill)
  local c = chars[key]
  local p = c and c.professions and c.professions.skills and c.professions.skills[skill]
  if not p then return nil end
  if key == self:MyKey() then
    local live = Core.Player:KnownRecipes(skill)
    if live then return live.ids, p end
  end
  if not p.recipes then return nil, p end
  local cacheKey = key .. "#" .. skill
  local set = unpacked[cacheKey]
  if not set then
    set = Store.UnpackIds(p.recipes)
    unpacked[cacheKey] = set
  end
  return set, p
end

---Which of your characters know a recipe, from the record of the profession that teaches it.
function Store:Knows(key, spellId, skill)
  local set = self:Recipes(key, skill)
  if not set then return nil end
  return set[spellId] == true
end

-------------------------------------------------------------------------------------------
-- Rest: what it was when last seen, carried forward. The game gives 5% of a level per 8 hours at an
-- inn and a quarter of that outside, up to 150%; for an offline character this is an estimate.
-------------------------------------------------------------------------------------------

local EIGHT_HOURS = 8 * 3600

---Rested share of a level (0 to 1.5) and whether it is an estimate; nil at the level cap or when unread.
function Store:Rest(key)
  local c = chars[key]
  if not (c and c.xpMax and c.xpMax > 0) then return nil end
  if (c.level or 0) >= (R.Global("GetMaxPlayerLevel") or 60) then return nil end
  local base = (c.rest or 0) / c.xpMax
  if key == self:MyKey() then return math.min(1.5, base), false end
  local elapsed = math.max(0, R.Now() - (c.seen or R.Now()))
  local rate = c.resting and .05 or .0125
  return math.min(1.5, base + elapsed / EIGHT_HOURS * rate), elapsed > 0
end

-------------------------------------------------------------------------------------------
-- Names and qualities
-------------------------------------------------------------------------------------------

---An item's name: the client's language through NorgannonDB, what a link told us, the client, else "Item #id".
function Store:ItemName(id)
  local name = Core.DB:Name("items", id) or R.db.names[id]
  if name then return name end
  name = R.In("C_Item", "GetItemNameByID", id)
  if name then return name end
  R.In("C_Item", "RequestLoadItemDataByID", id)
  return "Item #" .. id
end

---An item's quality: what a scan saw, else what the client knows, else nil.
function Store:ItemQuality(id, seen)
  return seen or R.In("C_Item", "GetItemQualityByID", id)
end

-- a late item name or quality redraws what is on screen
Core:On("ITEM_DATA_LOAD_RESULT", "retrospect.items", function()
  if R.Window then R.Window:RefreshSoon() end
end)

local function splitGuild(key)
  local realm, name = Character.Split(key)
  if realm and not realm:find("^%d+$") then return realm, name end
end

-- the key of this character's guild, for the shared holdings
function Store:GuildKey(c)
  if not c.guild then return nil end
  local key = (Character.Server() or "") .. "-" .. c.guild
  local old = Character.Mine(R.db.guilds, c.guild, { split = splitGuild })
  if old and old ~= key then
    R.db.guilds[key] = R.db.guilds[key] or R.db.guilds[old]
    R.db.guilds[old] = nil
    if R.Index then R.Index:Invalidate() end
  end
  return key
end
