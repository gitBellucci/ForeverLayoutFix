--[[
  Squid 4.1
  Named layout profiles: addon options, macros, keybinds, action bars,
  CVars, and Edit Mode. Save a layout on any character, Enable it on
  a new character or to switch layouts on the same one.
  Addon SavedVariables now persist on their own. This addon no longer
  rewrites them at login and does not need a disk/CMD publish step.
  /squid — create, save, and enable layouts.
]]

local ADDON_NAME = ...

ForeverLayoutFixDB = ForeverLayoutFixDB or {}
ForeverLayoutFixDB.vars = ForeverLayoutFixDB.vars or {}
ForeverLayoutFixDB.varNames = ForeverLayoutFixDB.varNames or {}
ForeverLayoutFixAccountDB = ForeverLayoutFixAccountDB or {}
ForeverLayoutFixProfilesDB = ForeverLayoutFixProfilesDB or {}

do
	local function mergeProfileStores(dst, src)
		if type(src) ~= "table" then
			return dst
		end
		dst = type(dst) == "table" and dst or {}
		if type(dst.profiles) ~= "table" then
			dst.profiles = {}
		end
		if type(src.profiles) == "table" then
			for name, rec in pairs(src.profiles) do
				if type(name) == "string" and type(rec) == "table" then
					local have = dst.profiles[name]
					if type(have) ~= "table" or type(have.pack) ~= "table" then
						dst.profiles[name] = rec
					elseif type(rec.pack) == "table" and (rec.savedAt or 0) >= (have.savedAt or 0) then
						dst.profiles[name] = rec
					end
				end
			end
		end
		if type(src.activeProfile) == "string" and src.activeProfile ~= "" then
			if type(dst.activeProfile) ~= "string" or dst.activeProfile == "" or type(dst.profiles[dst.activeProfile]) ~= "table" then
				dst.activeProfile = src.activeProfile
			end
		end
		if dst.profileEnabled == nil then
			dst.profileEnabled = src.profileEnabled
		end
		return dst
	end
	ForeverLayoutFixProfilesDB = mergeProfileStores(ForeverLayoutFixProfilesDB, rawget(_G, "FLF_PublishedSnapshot"))
	ForeverLayoutFixProfilesDB = mergeProfileStores(ForeverLayoutFixProfilesDB, rawget(_G, "FLF_DiskProfiles"))
end

local hooked = {}
local discovered = {}
local debugOn = ForeverLayoutFixDB.debug == true
local loginRestoreStarted = false
local leaPlusLCRef
local leatrixImportPending = false
local savedProfileThisSession = false
-- Baganator account SavedVariables usually load. Keep them unless we are
-- applying a layout copied from another character (or Enable was clicked).
local snapshotPrefer = {}

local EXTRA_GLOBALS = {
	"Blizzard_PTRIssueReporter_Saved",
	"LeaPlusDB",
	"LeaMapsDB",
	"RXPData",
	"RXPDB",
	"RXPSettings",
	"RXPString",
	"RXPCData",
	"RXPCComms",
	"RXPCSettings",
	"Bartender4DB",
	"PlaterDB",
	"SexyMap2DB",
	"XLootADB",
	"XLootOptions",
	"MSUF_DB",
	"MSUF_GlobalDB",
	"MSUF_ActiveProfile",
	"EllesmereUIDB",
	"MinimapButtonButtonOptions",
	-- DamageForever (Details!): names do not end in DB / Options
	"_detalhes_global",
	"_detalhes_database",
	"ThreatForeverDB",
	"DetailsTinyThreatDB",
	"PLATYNATOR_CONFIG",
	"PLATYNATOR_CURRENT_PROFILE",
	"PLATYNATOR_LAST_INSTANCE",
	"BAGANATOR_CONFIG",
	"BAGANATOR_CURRENT_PROFILE",
	"SYNDICATOR_CONFIG",
	"AUCTIONATOR_SAVEDVARS",
	"AUCTIONATOR_CHARACTER_CONFIG",
	"AUCTIONATOR_SHOPPING_LISTS",
	"BugSackLDBIconDB",
	-- WIM / GODMODE Messenger (legacy WIM3_* store; names do not end in DB)
	"WIM3_Data",
	"WIM3_Filters",
	"WIM3_ChatFilters",
	"WIM3_Alias",
}

local EXTRA_SET = {}
for i = 1, #EXTRA_GLOBALS do
	EXTRA_SET[EXTRA_GLOBALS[i]] = true
end

local SKIP = {
	ForeverLayoutFixDB = true,
	ForeverLayoutFixAccountDB = true,
	ForeverLayoutFixProfilesDB = true,
	FLF_PublishedSnapshot = true,
	FLF_DiskProfiles = true,
	FLF_OfflineFallback = true,
	FLF_PreDumpAccountDB = true,
	FLF_PreDumpFallback = true,
	FLF_PreDumpCharDB = true,
}

local SKIP_EXACT = {
	UIParent = true,
	WorldFrame = true,
	DEFAULT_CHAT_FRAME = true,
	Settings = true,
	NewSettings = true,
	C_VideoOptions = true,
	C_TTSSettings = true,
	NamePlateSetupOptions = true,
	WeakAurasSaved = true,
	WeakAurasArchive = true,
	WeakAurasOptionsSaved = true,
}

local function chat(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff00ff88[Squid]|r " .. tostring(msg))
	end
end

local function dbg(msg)
	if debugOn then
		chat("|cffaaaaaa" .. tostring(msg))
	end
end

local function getNumAddOns()
	if C_AddOns and C_AddOns.GetNumAddOns then
		return C_AddOns.GetNumAddOns()
	end
	return GetNumAddOns()
end

local function getAddOnInfo(i)
	if C_AddOns and C_AddOns.GetAddOnInfo then
		return C_AddOns.GetAddOnInfo(i)
	end
	return GetAddOnInfo(i)
end

local function getAddOnMetadata(name, field)
	local v
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		v = C_AddOns.GetAddOnMetadata(name, field)
	end
	if (not v or v == "") and GetAddOnMetadata then
		v = GetAddOnMetadata(name, field)
	end
	return v
end

local function splitVars(s)
	local t = {}
	if type(s) ~= "string" or s == "" then
		return t
	end
	for part in string.gmatch(s, "[^,%s]+") do
		t[#t + 1] = part
	end
	return t
end

local function isAceAddonObject(v)
	return type(v) == "table" and type(v.sv) == "table" and type(v.SetProfile) == "function"
end

local function isCacheName(name)
	if type(name) ~= "string" then
		return false
	end
	return name:sub(-5) == "_DATA"
		or name:sub(-10) == "_SUMMARIES"
		or name:sub(-15) == "_PRICE_DATABASE"
		or name:sub(-16) == "_POSTING_HISTORY"
		or name:sub(-19) == "_VENDOR_PRICE_CACHE"
end

local function isUnsafeGlobal(name)
	if type(name) ~= "string" or name == "" then
		return true
	end
	-- Questie compiled streams break if copied. Never snapshot or inject.
	if name:sub(1, 7) == "Questie" then
		return true
	end
	if EXTRA_SET[name] then
		return false
	end
	if SKIP[name] or SKIP_EXACT[name] or isCacheName(name) then
		return true
	end
	if name:sub(1, 2) == "C_" then
		return true
	end
	if name:sub(1, 8) == "Blizzard" then
		return true
	end
	if name:sub(1, 10) == "ChatConfig" or name:sub(1, 12) == "CombatConfig" then
		return true
	end
	if name:sub(1, 8) == "Garrison" or name:sub(1, 11) == "CustomAura" then
		return true
	end
	if name:sub(1, 4) == "ERR_" then
		return true
	end
	if name:find("CategoryData$") or name:find("DefaultOptions$") then
		return true
	end
	if name:find("SoundData$") or name:find("Mixin$") then
		return true
	end
	-- Huge messenger caches — settings live in WIM3_Data, not these.
	if name == "WIM3_Cache" or name == "WIM3_History" then
		return true
	end
	-- Questie quest DB is tens of MB and explodes account SavedVariables.
	if name == "QuestieForeverDB" or name == "RXPCTrackingData" then
		return true
	end
	return false
end

local function rememberName(varName)
	if not varName or varName == "" or isUnsafeGlobal(varName) then
		return
	end
	discovered[varName] = true
	ForeverLayoutFixDB.varNames[varName] = true
end

local GUESS_SUFFIXES = {
	"DB",
	"2DB",
	"Options",
	"_DB",
	"_Options",
	"Settings",
	"SavedVars",
	"SavedVariables",
	"_CONFIG",
	"CONFIG",
	"_CURRENT_PROFILE",
	"_SAVEDVARS",
	"_CHARACTER_CONFIG",
	"_LAST_INSTANCE",
	"_GlobalDB",
	"_ActiveProfile",
	"Data",
}

local function harvestGuesses(addonName)
	if not addonName or addonName == ADDON_NAME then
		return
	end
	local stripped = addonName:gsub("[^%w]", "")
	local acronym = addonName:gsub("[^A-Z]", "")
	local bases = { addonName, addonName:upper(), stripped, stripped:upper() }
	if type(acronym) == "string" and #acronym >= 3 then
		bases[#bases + 1] = acronym
		bases[#bases + 1] = acronym:upper()
	end
	local seen = {}
	for b = 1, #bases do
		local base = bases[b]
		if base and base ~= "" and not seen[base] then
			seen[base] = true
			for i = 1, #GUESS_SUFFIXES do
				local guess = base .. GUESS_SUFFIXES[i]
				if _G[guess] ~= nil then
					rememberName(guess)
				end
			end
		end
	end
end

local function harvestMetadata(addonName)
	if not addonName or addonName == ADDON_NAME then
		return
	end
	for _, field in ipairs({ "SavedVariables", "SavedVariablesPerCharacter" }) do
		local list = splitVars(getAddOnMetadata(addonName, field))
		for i = 1, #list do
			rememberName(list[i])
		end
	end
	harvestGuesses(addonName)
end

local function looksLikeSavedVars(name, value)
	if type(name) ~= "string" or isUnsafeGlobal(name) then
		return false
	end
	if isAceAddonObject(value) then
		return false
	end
	local vt = type(value)
	if vt ~= "table" and vt ~= "string" and vt ~= "number" and vt ~= "boolean" then
		return false
	end
	if name:find("Frame", 1, true) or name:find("Button", 1, true) then
		return false
	end
	-- WIM / GODMODE Messenger style: WIM3_Data (not *DB)
	if name:find("^WIM%d+_") and vt == "table" then
		return true
	end
	if (name:find("GODMODE", 1, true) or name:find("GodMode", 1, true) or name:find("Messenger", 1, true))
		and (name:find("DB$") or name:find("Data$") or name:find("Settings$"))
		and vt == "table" then
		return true
	end
	return name:find("DB$")
		or name:find("2DB$")
		or name:find("_CONFIG$")
		or name:find("SavedVars$")
		or name:find("_CURRENT_PROFILE$")
		or name:find("_ActiveProfile$")
		or name:find("_LAST_INSTANCE$")
		-- DamageForever account + character tables (_detalhes_global / _detalhes_database)
		or (name:find("^_detalhes_") and vt == "table")
		-- Addon Foo3_Data / Foo_Data, but not Blizzard *CategoryData (filtered above)
		or (name:find("_%d*Data$") or name:find("%d_Data$")) and vt == "table"
end

local function harvestScanGlobals()
	local n = 0
	for k, v in pairs(_G) do
		if looksLikeSavedVars(k, v) then
			rememberName(k)
			n = n + 1
		end
	end
	dbg("global scan matched " .. n .. " names")
end

local function harvestAllAddOns()
	local n = getNumAddOns()
	for i = 1, n do
		local name = getAddOnInfo(i)
		harvestMetadata(name)
	end
	for i = 1, #EXTRA_GLOBALS do
		rememberName(EXTRA_GLOBALS[i])
	end
	if type(ForeverLayoutFixDB.varNames) == "table" then
		for name in pairs(ForeverLayoutFixDB.varNames) do
			if isUnsafeGlobal(name) then
				ForeverLayoutFixDB.varNames[name] = nil
				if type(ForeverLayoutFixDB.vars) == "table" then
					ForeverLayoutFixDB.vars[name] = nil
				end
			else
				discovered[name] = true
			end
		end
	end
	if type(ForeverLayoutFixDB.vars) == "table" then
		for name in pairs(ForeverLayoutFixDB.vars) do
			rememberName(name)
		end
	end
end

local function copyClean(value, seen, depth)
	local t = type(value)
	if t == "number" or t == "string" or t == "boolean" then
		return value
	end
	if t ~= "table" then
		return nil
	end
	depth = depth or 0
	if depth > 50 then
		return nil
	end
	seen = seen or {}
	if seen[value] then
		return seen[value]
	end
	if isAceAddonObject(value) then
		return copyClean(value.sv, seen, depth)
	end
	local out = {}
	seen[value] = out
	for k, v in pairs(value) do
		local tk = type(k)
		if tk == "string" or tk == "number" then
			local vt = type(v)
			if vt ~= "function" and vt ~= "userdata" and vt ~= "thread" then
				out[k] = copyClean(v, seen, depth + 1)
			end
		end
	end
	return out
end

local function substance(value, limit)
	limit = limit or 400
	local t = type(value)
	if t == "string" or t == "number" or t == "boolean" then
		return 1
	end
	if t ~= "table" then
		return 0
	end
	local n = 0
	for _, v in pairs(value) do
		n = n + 1
		if type(v) == "table" then
			n = n + substance(v, limit)
		end
		if n > limit then
			return limit
		end
	end
	return n
end

local function mergeInto(dest, src)
	if type(dest) ~= "table" or type(src) ~= "table" then
		return
	end
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dest[k]) == "table" then
				mergeInto(dest[k], v)
			else
				dest[k] = copyClean(v)
			end
		else
			dest[k] = v
		end
	end
end

local function foreverNameKeys()
	local name, realm = UnitName("player"), GetRealmName()
	if not name or not realm then
		return {}
	end
	local first = name:match("^(%S+)") or name
	return {
		name .. "-" .. realm,
		name .. " - " .. realm,
		first .. "-" .. realm,
		first .. " - " .. realm,
	}
end

-- Forever AceDB uses ruleset names (PvE/PvP/Hardcore/RP) as the realm part of
-- charKey, not GetRealmName(). Layout profiles must bind both spellings or
-- addons like RXP create a fresh empty profile on alts.
local ACE_REALM_ALIASES = { "PvE", "PvP", "Hardcore", "RP" }

local function aceCharKeyVariants(player, realm)
	local out, seen = {}, {}
	if type(player) ~= "string" or player == "" then
		return out
	end
	local first = player:match("^(%S+)") or player
	local function add(value)
		if type(value) == "string" and value ~= "" and not seen[value] then
			seen[value] = true
			out[#out + 1] = value
		end
	end
	local realms, rseen = {}, {}
	local function addRealm(r)
		if type(r) == "string" and r ~= "" and not rseen[r] then
			rseen[r] = true
			realms[#realms + 1] = r
		end
	end
	addRealm(realm)
	for i = 1, #ACE_REALM_ALIASES do
		addRealm(ACE_REALM_ALIASES[i])
	end
	for i = 1, #realms do
		local r = realms[i]
		add(player .. " - " .. r)
		add(player .. "-" .. r)
		add(first .. " - " .. r)
		add(first .. "-" .. r)
	end
	add(player)
	add(first)
	return out
end

local function foreverAceNameKeys()
	return aceCharKeyVariants(UnitName("player"), GetRealmName())
end

local function chooseAceProfileName(tbl)
	if type(tbl) ~= "table" or type(tbl.profiles) ~= "table" then
		return
	end
	local function fromKeys(player, realm)
		local try = aceCharKeyVariants(player, realm)
		for i = 1, #try do
			local key = try[i]
			if type(tbl.profileKeys) == "table" then
				local pname = tbl.profileKeys[key]
				if type(pname) == "string" and type(tbl.profiles[pname]) == "table" then
					return pname
				end
			end
			if type(tbl.profiles[key]) == "table" then
				return key
			end
		end
	end
	local saved = fromKeys(ForeverLayoutFixDB.lastSavePlayer, ForeverLayoutFixDB.lastSaveRealm or GetRealmName())
	if saved then
		return saved
	end
	local richest, richestn
	if type(tbl.profileKeys) == "table" then
		for _, prof in pairs(tbl.profileKeys) do
			if type(prof) == "string" and type(tbl.profiles[prof]) == "table" then
				local n = substance(tbl.profiles[prof], 100000)
				if not richestn or n > richestn then
					richest, richestn = prof, n
				end
			end
		end
	end
	if richest then
		return richest
	end
	for name, prof in pairs(tbl.profiles) do
		if type(prof) == "table" then
			local n = substance(prof, 100000)
			if not richestn or n > richestn then
				richest, richestn = name, n
			end
		end
	end
	return richest
end

local function aliasForeverNameMap(tbl)
	if type(tbl) ~= "table" then
		return
	end
	local realm = GetRealmName()
	if not realm then
		return
	end
	local keys = foreverNameKeys()
	local best, bestn
	for k, v in pairs(tbl) do
		if type(k) == "string" and type(v) == "table" and string.find(k, realm, 1, true) then
			local n = substance(v)
			if not bestn or n > bestn then
				best, bestn = v, n
			end
		end
	end
	if best and bestn > 0 then
		for i = 1, #keys do
			local key = keys[i]
			local current = tbl[key]
			if current == nil then
				tbl[key] = copyClean(best)
			elseif current ~= best and type(current) == "table" then
				if substance(current) < bestn then
					mergeInto(current, best)
				elseif type(best.activeProfile) == "string" and best.activeProfile ~= "" and best.activeProfile ~= "Default"
					and (type(current.activeProfile) ~= "string" or current.activeProfile == "" or current.activeProfile == "Default") then
					current.activeProfile = best.activeProfile
				end
			end
		end
	end
end

local function aliasForeverNames(tbl)
	if type(tbl) ~= "table" then
		return
	end
	if type(tbl.profileKeys) == "table" and type(tbl.profiles) == "table" then
		local richest = chooseAceProfileName(tbl)
		if richest then
			local keys = foreverAceNameKeys()
			for i = 1, #keys do
				tbl.profileKeys[keys[i]] = richest
			end
		end
	end
	aliasForeverNameMap(tbl)
	-- MSUF and similar store per-character bindings under .char, not at the root.
	aliasForeverNameMap(tbl.char)
	aliasForeverNameMap(tbl.chars)
	aliasForeverNameMap(tbl.characters)
	-- Baganator stores per-character options under CharacterSpecific[option][name].
	if type(tbl.CharacterSpecific) == "table" then
		for _, sub in pairs(tbl.CharacterSpecific) do
			if type(sub) == "table" then
				aliasForeverNameMap(sub)
			end
		end
	end
end

local function varsCount()
	local vars = ForeverLayoutFixDB.vars
	if type(vars) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(vars) do
		n = n + 1
	end
	return n
end

local function varsAreEmpty()
	return varsCount() == 0
end

local function packSubstance(pack)
	if type(pack) ~= "table" or type(pack.vars) ~= "table" then
		return 0
	end
	return substance(pack.vars)
end

local function applyPack(pack)
	if type(pack) ~= "table" then
		return false
	end
	if type(pack.vars) ~= "table" or not next(pack.vars) then
		return false
	end
	ForeverLayoutFixDB.vars = pack.vars
	if type(pack.varNames) == "table" then
		ForeverLayoutFixDB.varNames = pack.varNames
	end
	for k, v in pairs(pack) do
		if k ~= "vars" and k ~= "varNames" then
			ForeverLayoutFixDB[k] = v
		end
	end
	return true
end

-- Restore from account mirror. Unused since 4.0: native SavedVariables load.
local function hydrateFromAccount()
	return false
end

local function saveAccountMirror()
end

local function refreshOfflineFallbackExport()
	return false
end

local function applyOfflineFallback()
	return false
end

local PROFILE_SKIP_VARS = {
	QuestieForeverDB = true,
	QuestieConfig = true,
	QuestieConfigCharacter = true,
	QuestieProfilerEnabled = true,
	RXPCTrackingData = true,
	-- Details debug / old-config backups, not layout
	__details_backup = true,
	__details_debug = true,
}

-- Combat logs and live instance objects are not layout and explode copyClean.
local DETAILS_CHAR_SKIP = {
	tabela_historico = true,
	tabela_overall = true,
	tabela_instancias = true,
	saved_pet_cache = true,
	nick_tag_cache = true,
	tabela_vigente = true,
	damage_meter_sessions = true,
}

local function copyDetailsCharacterDB(src)
	if type(src) ~= "table" then
		return copyClean(src)
	end
	local out = {}
	for k, v in pairs(src) do
		if not DETAILS_CHAR_SKIP[k] then
			out[k] = copyClean(v)
		end
	end
	return out
end

local function slimCopiedDetailsGlobal(copied)
	if type(copied) ~= "table" then
		return copied
	end
	copied.exit_log = nil
	copied.exit_errors = nil
	copied.report_lines = nil
	return copied
end

local function detailsAddon()
	local d = rawget(_G, "Details") or rawget(_G, "_detalhes")
	if type(d) == "table" and (type(d.SaveProfile) == "function" or type(d.ApplyProfile) == "function") then
		return d
	end
end

local function rememberDetailsNames()
	rememberName("_detalhes_global")
	rememberName("_detalhes_database")
	rememberName("ThreatForeverDB")
	rememberName("DetailsTinyThreatDB")
end

local function ensureProfileStore()
	ForeverLayoutFixProfilesDB = ForeverLayoutFixProfilesDB or {}
	local db = ForeverLayoutFixProfilesDB
	if type(db.profiles) ~= "table" then
		db.profiles = {}
	end
	-- One-time move off the bloated account table.
	local acc = ForeverLayoutFixAccountDB
	if type(acc) == "table" and type(acc.profiles) == "table" and next(acc.profiles) and not next(db.profiles) then
		db.profiles = acc.profiles
		db.activeProfile = acc.activeProfile
		db.profileEnabled = acc.profileEnabled
		acc.profiles = nil
		acc.activeProfile = nil
		acc.profileEnabled = nil
	end
	return db
end

local function sanitizeProfileName(name)
	name = strtrim(tostring(name or ""))
	name = name:gsub("[%c/\\:*?\"<>|]", "")
	if name == "" or #name > 40 then
		return nil
	end
	if name:sub(1, 1) == "_" or name == "profiles" then
		return nil
	end
	return name
end

local function stripProgress(pack)
	if type(pack) ~= "table" then
		return pack
	end
	if type(pack.vars) == "table" then
		for k in pairs(PROFILE_SKIP_VARS) do
			pack.vars[k] = nil
		end
	end
	if type(pack.varNames) == "table" then
		for k in pairs(PROFILE_SKIP_VARS) do
			pack.varNames[k] = nil
		end
	end
	return pack
end

local function scrubPack(pack)
	pack = stripProgress(pack)
	if type(pack) ~= "table" then
		return pack
	end
	local drop = {
		ForeverLayoutFixProfilesDB = true,
		ForeverLayoutFixAccountDB = true,
		ForeverLayoutFixDB = true,
		FLF_PublishedSnapshot = true,
		FLF_DiskProfiles = true,
		FLF_OfflineFallback = true,
		FLF_PreDumpAccountDB = true,
		FLF_PreDumpFallback = true,
		FLF_PreDumpCharDB = true,
	}
	if type(pack.vars) == "table" then
		for k in pairs(drop) do
			pack.vars[k] = nil
		end
	end
	if type(pack.varNames) == "table" then
		for k in pairs(drop) do
			pack.varNames[k] = nil
		end
	end
	return pack
end

local function applyActiveProfilePack()
	local acc = ensureProfileStore()
	if type(acc) ~= "table" then
		return false
	end
	local name = acc.activeProfile
	if type(name) ~= "string" or name == "" or type(acc.profiles) ~= "table" then
		return false
	end
	local rec = acc.profiles[name]
	if type(rec) ~= "table" or type(rec.pack) ~= "table" then
		return false
	end
	local pack = scrubPack(copyClean(rec.pack))
	if not applyPack(pack) then
		return false
	end
	local me = UnitName("player")
	if type(rec.savedPlayer) == "string" and type(me) == "string" and rec.savedPlayer ~= me then
		snapshotPrefer.BAGANATOR_CONFIG = true
		snapshotPrefer.BAGANATOR_CURRENT_PROFILE = true
		snapshotPrefer.SYNDICATOR_CONFIG = true
	end
	if type(ForeverLayoutFixDB.vars) == "table" then
		for _, v in pairs(ForeverLayoutFixDB.vars) do
			if type(v) == "table" then
				aliasForeverNames(v)
			end
		end
	end
	return true, name
end

local function listProfileNames()
	local acc = ensureProfileStore()
	local names = {}
	for k, rec in pairs(acc.profiles) do
		if type(k) == "string" and type(rec) == "table" then
			names[#names + 1] = k
		end
	end
	table.sort(names)
	return names
end

local function eachTrackedName(fn)
	harvestAllAddOns()
	harvestScanGlobals()
	for name in pairs(discovered) do
		if not SKIP[name] then
			fn(name)
		end
	end
end

local SHADOW_SUFFIXES = { "LC", "PC" }

local function eachShadow(varName, fn)
	if type(varName) ~= "string" then
		return
	end
	local base = varName:gsub("2DB$", ""):gsub("DB$", "")
	if base == varName or base == "" then
		return
	end
	for i = 1, #SHADOW_SUFFIXES do
		local shadow = _G[base .. SHADOW_SUFFIXES[i]]
		if type(shadow) == "table" and shadow ~= _G[varName] then
			fn(shadow)
		end
	end
end

local LEATRIX_SKIP_LC_KEYS = {
	AddonVer = true,
	ShowErrorsFlag = true,
	NumberOfPages = true,
	MainPanelHeight = true,
	NewPatch = true,
	ElvUI = true,
	RaidColors = true,
}

local function isLeatrixSettingValue(v)
	local t = type(v)
	return t == "string" or t == "number" or t == "boolean"
end

local function copyLeatrixSettings(src, dest)
	if type(src) ~= "table" or type(dest) ~= "table" then
		return 0
	end
	local n = 0
	for k, v in pairs(src) do
		if type(k) == "string" and not LEATRIX_SKIP_LC_KEYS[k] and isLeatrixSettingValue(v) then
			local cur = dest[k]
			if type(cur) ~= "function" and type(cur) ~= "table" then
				dest[k] = v
				n = n + 1
			end
		end
	end
	return n
end

local function readUpvalue(fn, want)
	if type(fn) ~= "function" then
		return
	end
	local getter = (debug and debug.getupvalue) or _G.getupvalue
	if type(getter) ~= "function" then
		return
	end
	for i = 1, 24 do
		local ok, name, val = pcall(getter, fn, i)
		if not ok or name == nil then
			break
		end
		if name == want and type(val) == "table" and (val.LoadVarChk or val.PlayerLogout or val.SlashFunc) then
			return val
		end
	end
end

local function looksLikeLeatrixLC(tbl)
	return type(tbl) == "table" and (tbl.LoadVarChk or tbl.PlayerLogout or tbl.SlashFunc)
end

local function captureLeatrixLCFromFrame(frame, depth, budget)
	if not frame or (depth or 0) > 8 or (budget.count or 0) > 80 then
		return
	end
	budget.count = (budget.count or 0) + 1
	if frame.GetScript then
		local lc = readUpvalue(frame:GetScript("OnClick"), "LeaPlusLC")
			or readUpvalue(frame:GetScript("OnShow"), "LeaPlusLC")
			or readUpvalue(frame:GetScript("OnDragStop"), "LeaPlusLC")
		if lc then
			return lc
		end
	end
	if frame.GetChildren then
		local kids = { frame:GetChildren() }
		for i = 1, #kids do
			local found = captureLeatrixLCFromFrame(kids[i], (depth or 0) + 1, budget)
			if found then
				return found
			end
		end
	end
end

local function getLeaPlusLC()
	if looksLikeLeatrixLC(leaPlusLCRef) then
		return leaPlusLCRef
	end
	if looksLikeLeatrixLC(_G.LeaPlusLC) then
		leaPlusLCRef = _G.LeaPlusLC
		return leaPlusLCRef
	end
	local fns = {
		SlashCmdList and SlashCmdList.Leatrix_Plus,
		_G.LeaPlusGlobalMiniBtnClickFunc,
	}
	local panel = _G.LeaPlusGlobalPanel
	if panel and panel.GetScript then
		fns[#fns + 1] = panel:GetScript("OnDragStop")
		fns[#fns + 1] = panel:GetScript("OnShow")
		fns[#fns + 1] = panel:GetScript("OnHide")
	end
	for i = 1, #fns do
		local lc = readUpvalue(fns[i], "LeaPlusLC")
		if lc then
			leaPlusLCRef = lc
			if type(_G.LeaPlusLC) ~= "table" then
				_G.LeaPlusLC = lc
			end
			return lc
		end
	end
	if panel then
		local lc = captureLeatrixLCFromFrame(panel, 0, { count = 0 })
		if lc then
			leaPlusLCRef = lc
			if type(_G.LeaPlusLC) ~= "table" then
				_G.LeaPlusLC = lc
			end
			return lc
		end
	end
	return leaPlusLCRef
end

local function syncLeatrixToDB()
	local lc = getLeaPlusLC()
	if not lc then
		return false
	end
	local db = rawget(_G, "LeaPlusDB")
	if type(db) ~= "table" then
		db = {}
		_G.LeaPlusDB = db
	end
	copyLeatrixSettings(lc, db)
	for _, tblName in ipairs({ "muteTable", "mountTable", "transTable" }) do
		local tbl = lc[tblName]
		if type(tbl) == "table" then
			for k in pairs(tbl) do
				if isLeatrixSettingValue(lc[k]) then
					db[k] = lc[k]
				end
			end
		end
	end
	return true
end

local function applyLeatrixSnapshot(opts)
	opts = opts or {}
	local src = ForeverLayoutFixDB.vars and ForeverLayoutFixDB.vars.LeaPlusDB
	if type(src) ~= "table" then
		return false
	end
	local db = rawget(_G, "LeaPlusDB")
	if type(db) ~= "table" then
		db = {}
		_G.LeaPlusDB = db
	end
	mergeInto(db, src)
	local lc = getLeaPlusLC()
	if lc then
		copyLeatrixSettings(src, lc)
		for _, tblName in ipairs({ "muteTable", "mountTable", "transTable" }) do
			local tbl = lc[tblName]
			if type(tbl) == "table" then
				for k in pairs(tbl) do
					if isLeatrixSettingValue(src[k]) then
						lc[k] = src[k]
					end
				end
			end
		end
		leatrixImportPending = false
		return true
	end
	if opts.markPending then
		leatrixImportPending = true
	end
	return false
end

local function profileWantsFastMovieSkip()
	local function isOn(v)
		return v == "On" or v == true
	end
	local vars = ForeverLayoutFixDB.vars
	if type(vars) == "table" and type(vars.LeaPlusDB) == "table" and isOn(vars.LeaPlusDB.FasterMovieSkip) then
		return true
	end
	local acc = ForeverLayoutFixProfilesDB
	if type(acc) == "table" and acc.profileEnabled ~= false and type(acc.profiles) == "table" then
		local rec = type(acc.activeProfile) == "string" and acc.profiles[acc.activeProfile]
		local db = rec and rec.pack and rec.pack.vars and rec.pack.vars.LeaPlusDB
		if type(db) == "table" and isOn(db.FasterMovieSkip) then
			return true
		end
	end
	local live = rawget(_G, "LeaPlusDB")
	if type(live) == "table" and isOn(live.FasterMovieSkip) then
		return true
	end
	local lc = getLeaPlusLC()
	if lc and isOn(lc.FasterMovieSkip) then
		return true
	end
	return false
end

-- Opening cinematic only (new characters have 0 XP). Do not cancel later story movies.
local function isOpeningCinematic()
	if UnitExists and not UnitExists("player") then
		return true
	end
	local xp = UnitXP and UnitXP("player")
	return type(xp) ~= "number" or xp == 0
end

local function trySkipOpeningCinematic()
	if not profileWantsFastMovieSkip() or not isOpeningCinematic() then
		return
	end
	pcall(function()
		if StopCinematic then
			StopCinematic()
		end
	end)
	pcall(function()
		local f = _G.CinematicFrame
		if f and f.IsShown and f:IsShown() then
			local btn = _G.CinematicFrameCloseDialogConfirmButton
			if btn and btn.Click then
				if _G.CinematicFrameCloseDialog and _G.CinematicFrameCloseDialog.Hide then
					_G.CinematicFrameCloseDialog:Hide()
				end
				btn:Click()
			end
		end
	end)
	pcall(function()
		local f = _G.MovieFrame
		if not (f and f.IsShown and f:IsShown()) then
			return
		end
		if f.StopMovie then
			f:StopMovie()
		end
		if GameMovieFinished then
			GameMovieFinished()
		end
		local btn = f.CloseDialog and f.CloseDialog.Buttons and f.CloseDialog.Buttons.ConfirmButton
		if btn and btn.Click then
			btn:Click()
		end
	end)
end

local movieFramesHooked = {}
local function hookOpeningCinematicFrames()
	local function hook(frame)
		if type(frame) ~= "table" or movieFramesHooked[frame] or not frame.HookScript then
			return
		end
		movieFramesHooked[frame] = true
		frame:HookScript("OnShow", function()
			trySkipOpeningCinematic()
			if C_Timer and C_Timer.After then
				C_Timer.After(0, trySkipOpeningCinematic)
			end
		end)
	end
	hook(_G.CinematicFrame)
	hook(_G.MovieFrame)
end

local openingCinematicWatcher
local function watchOpeningCinematic()
	hookOpeningCinematicFrames()
	if openingCinematicWatcher then
		trySkipOpeningCinematic()
		return
	end
	openingCinematicWatcher = CreateFrame("Frame")
	openingCinematicWatcher:RegisterEvent("CINEMATIC_START")
	openingCinematicWatcher:RegisterEvent("PLAY_MOVIE")
	openingCinematicWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
	openingCinematicWatcher:SetScript("OnEvent", function()
		hookOpeningCinematicFrames()
		trySkipOpeningCinematic()
		if C_Timer and C_Timer.After then
			C_Timer.After(0, trySkipOpeningCinematic)
			C_Timer.After(0.25, trySkipOpeningCinematic)
		end
	end)
	trySkipOpeningCinematic()
end

local function liveTableFor(name)
	if name == "LeaPlusDB" then
		pcall(syncLeatrixToDB)
	end
	local v = _G[name]
	if isAceAddonObject(v) then
		v = v.sv
	end
	local live
	local usedShadow = false
	if name ~= "LeaPlusDB" then
		eachShadow(name, function(shadow)
			usedShadow = true
			live = live or (type(v) == "table" and copyClean(v) or {})
			for k, val in pairs(shadow) do
				local tk = type(k)
				if (tk == "string" or tk == "number") and type(val) ~= "function" then
					live[k] = type(val) == "table" and copyClean(val) or val
				end
			end
		end)
	else
		usedShadow = getLeaPlusLC() ~= nil
	end
	return live or v, usedShadow
end

-- AceDB keeps the live settings on db.profile (defaults mixed in until logout).
-- Copy that current profile into the snapshot so theme / frame positions / etc.
-- are stored even when they still match defaults or were only moved this session.
local function stampCurrentAceProfile(liveSv, copied)
	if type(liveSv) ~= "table" or type(copied) ~= "table" then
		return copied
	end
	local AceDB = LibStub and LibStub("AceDB-3.0", true)
	if not AceDB or type(AceDB.db_registry) ~= "table" then
		return copied
	end
	for db in pairs(AceDB.db_registry) do
		if type(db) == "table" and type(db.profile) == "table" then
			local pname = db.keys and db.keys.profile
			if type(pname) ~= "string" or pname == "" then
				pname = UnitName("player")
			end
			if type(pname) == "string" and pname ~= "" then
				if not db.parent and db.sv == liveSv then
					copied.profiles = copied.profiles or {}
					copied.profileKeys = copied.profileKeys or {}
					copied.profiles[pname] = copyClean(db.profile)
					local keys = foreverAceNameKeys()
					for i = 1, #keys do
						copied.profileKeys[keys[i]] = pname
					end
				elseif db.parent and db.parent.sv == liveSv then
					-- XLoot Frame/Monitor/etc. live in AceDB namespaces.
					local nsName = db.keys and db.keys.namespace
					if type(nsName) == "string" and nsName ~= "" then
						copied.namespaces = copied.namespaces or {}
						copied.namespaces[nsName] = copied.namespaces[nsName] or {}
						copied.namespaces[nsName].profiles = copied.namespaces[nsName].profiles or {}
						copied.namespaces[nsName].profiles[pname] = copyClean(db.profile)
					end
				end
			end
		end
	end
	return copied
end

local function snapshotVars(force)
	ForeverLayoutFixDB.vars = ForeverLayoutFixDB.vars or {}
	local count, skipped = 0, 0
	eachTrackedName(function(name)
		if isCacheName(name) or isUnsafeGlobal(name) or PROFILE_SKIP_VARS[name] then
			return
		end
		local ok, err = pcall(function()
			local v, usedShadow = liveTableFor(name)
			if v == nil then
				return
			end
			local copied
			if name == "_detalhes_database" then
				copied = copyDetailsCharacterDB(v)
			elseif name == "_detalhes_global" then
				copied = slimCopiedDetailsGlobal(copyClean(v))
			else
				copied = copyClean(v)
			end
			if copied == nil then
				dbg("skip snapshot " .. name)
				return
			end
			if type(copied) == "table" then
				local ident = _G[name]
				if isAceAddonObject(ident) then
					ident = ident.sv
				end
				stampCurrentAceProfile(ident, copied)
			end
			if type(copied) == "table" and next(copied) == nil then
				return
			end
			local old = ForeverLayoutFixDB.vars[name]
			-- Leatrix Plus keeps live settings in a LOCAL LeaPlusLC until logout.
			-- Mid-session /flf save would otherwise poison a good snapshot.
			local drop = old ~= nil and substance(copied) < math.max(2, substance(old) * 0.5)
			if name == "RXPCData" and type(old) == "table" then
				local oldName = type(old.currentGuideName) == "string" and old.currentGuideName or ""
				local newName = type(copied.currentGuideName) == "string" and copied.currentGuideName or ""
				if oldName ~= "" and newName == "" then
					drop = true
				end
			end
			if name == "_detalhes_global" or name == "_detalhes_database" or name == "SexyMap2DB" or name == "XLootADB" then
				drop = false
			end
			if drop and (not force or not usedShadow) then
				skipped = skipped + 1
				dbg("kept richer snapshot for " .. name)
				return
			end
			ForeverLayoutFixDB.vars[name] = copied
			count = count + 1
		end)
		if not ok then
			dbg("skip snapshot " .. name .. " (" .. tostring(err) .. ")")
		end
	end)
	if type(ForeverLayoutFixDB.vars) == "table" then
		for name in pairs(ForeverLayoutFixDB.vars) do
			if isUnsafeGlobal(name) then
				ForeverLayoutFixDB.vars[name] = nil
				if ForeverLayoutFixDB.varNames then
					ForeverLayoutFixDB.varNames[name] = nil
				end
			end
		end
	end
	dbg("snapshot wrote " .. count .. ", protected " .. skipped)
	-- Always pin bag addon settings. These are account-wide and Baganator
	-- writes them live; a missed harvest used to drop them from the profile.
	pcall(function()
		rememberName("BAGANATOR_CONFIG")
		rememberName("BAGANATOR_CURRENT_PROFILE")
		rememberName("SYNDICATOR_CONFIG")
		local cfg = rawget(_G, "BAGANATOR_CONFIG")
		if type(cfg) == "table" then
			local copied = copyClean(cfg)
			if type(copied) == "table" and next(copied) then
				ForeverLayoutFixDB.vars.BAGANATOR_CONFIG = copied
			end
		end
		local pname = rawget(_G, "BAGANATOR_CURRENT_PROFILE")
		if type(pname) == "string" and pname ~= "" then
			ForeverLayoutFixDB.vars.BAGANATOR_CURRENT_PROFILE = pname
		end
		local syn = rawget(_G, "SYNDICATOR_CONFIG")
		if type(syn) == "table" then
			local copied = copyClean(syn)
			if type(copied) == "table" and next(copied) then
				ForeverLayoutFixDB.vars.SYNDICATOR_CONFIG = copied
			end
		end
		rememberDetailsNames()
		local xloot = rawget(_G, "XLootADB")
		if type(xloot) == "table" then
			rememberName("XLootADB")
			local copied = copyClean(xloot)
			if type(copied) == "table" then
				stampCurrentAceProfile(xloot, copied)
				if next(copied) then
					ForeverLayoutFixDB.vars.XLootADB = copied
				end
			end
		end
		local smap = rawget(_G, "SexyMap2DB")
		if type(smap) == "table" then
			rememberName("SexyMap2DB")
			local copied = copyClean(smap)
			if type(copied) == "table" and next(copied) then
				ForeverLayoutFixDB.vars.SexyMap2DB = copied
			end
		end
		local glob = rawget(_G, "_detalhes_global")
		if type(glob) == "table" then
			local copied = slimCopiedDetailsGlobal(copyClean(glob))
			if type(copied) == "table" and next(copied) then
				ForeverLayoutFixDB.vars._detalhes_global = copied
			end
		end
		local charDB = rawget(_G, "_detalhes_database")
		if type(charDB) == "table" then
			local copied = copyDetailsCharacterDB(charDB)
			if type(copied) == "table" and next(copied) then
				ForeverLayoutFixDB.vars._detalhes_database = copied
			end
		end
		local threat = rawget(_G, "ThreatForeverDB") or rawget(_G, "DetailsTinyThreatDB")
		if type(threat) == "table" and next(threat) then
			local copied = copyClean(threat)
			if type(copied) == "table" and next(copied) then
				if rawget(_G, "ThreatForeverDB") == threat then
					ForeverLayoutFixDB.vars.ThreatForeverDB = copied
				else
					ForeverLayoutFixDB.vars.DetailsTinyThreatDB = copied
				end
			end
		end
	end)
	return count
end

local function rehydrateShadow(varName, src)
	if type(src) ~= "table" or type(varName) ~= "string" then
		return
	end
	eachShadow(varName, function(shadow)
		if shadow == src then
			return
		end
		for k, v in pairs(src) do
			if type(shadow[k]) ~= "function" then
				if type(v) == "table" then
					if type(shadow[k]) == "table" then
						mergeInto(shadow[k], v)
					else
						shadow[k] = copyClean(v)
					end
				else
					shadow[k] = v
				end
			end
		end
	end)
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	if ace and ace.GetAddon then
		local addonName = varName:gsub("2DB$", ""):gsub("DB$", "")
		local addon = addonName ~= varName and ace:GetAddon(addonName, true)
		if addon and type(addon.db) == "table" then
			if type(addon.db.sv) == "table" then
				mergeInto(addon.db.sv, src)
			elseif type(addon.db.profile) == "table" and type(src.profiles) == "table" then
				mergeInto(addon.db, src)
			end
		end
	end
end

local function wipeMerge(dest, src)
	if type(dest) ~= "table" or type(src) ~= "table" then
		return
	end
	if dest == src then
		return
	end
	for k in pairs(dest) do
		dest[k] = nil
	end
	mergeInto(dest, src)
end

local function pickSourceAceProfile(sv)
	if type(sv) ~= "table" or type(sv.profiles) ~= "table" then
		return
	end
	local pname = chooseAceProfileName(sv)
	if type(pname) == "string" and type(sv.profiles[pname]) == "table" then
		return pname, sv.profiles[pname]
	end
end

local function bindAceSavedVars(opts)
	opts = opts or {}
	local switchProfile = opts.switchProfile == true
	local vars = ForeverLayoutFixDB.vars
	if type(vars) == "table" then
		for name, _ in pairs(vars) do
			local dest = _G[name]
			if isAceAddonObject(dest) then
				dest = dest.sv
			end
			if type(dest) == "table" then
				aliasForeverNames(dest)
				local pname, prof = pickSourceAceProfile(dest)
				if pname and prof then
					dest.profileKeys = dest.profileKeys or {}
					dest.profiles = dest.profiles or {}
					local keys = foreverAceNameKeys()
					for i = 1, #keys do
						dest.profileKeys[keys[i]] = pname
						if type(dest.profiles[keys[i]]) == "table" and dest.profiles[keys[i]] ~= prof then
							wipeMerge(dest.profiles[keys[i]], prof)
						end
					end
				end
			end
		end
	end
	if not switchProfile then
		return
	end
	local function switchDb(db)
		if type(db) ~= "table" or type(db.sv) ~= "table" or type(db.SetProfile) ~= "function" then
			return
		end
		local pname, prof = pickSourceAceProfile(db.sv)
		-- Copy first: SetProfile can fire OnProfileChanged handlers that write
		-- the current (wrong) frame positions into the source profile.
		local saved = type(prof) == "table" and copyClean(prof) or nil
		if pname then
			pcall(function()
				db:SetProfile(pname)
			end)
		end
		if type(db.profile) == "table" and type(saved) == "table" then
			wipeMerge(db.profile, saved)
		end
	end
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	if ace and ace.IterateAddons then
		for _, addon in ace:IterateAddons() do
			switchDb(addon.db)
		end
	end
	local AceDB = LibStub and LibStub("AceDB-3.0", true)
	if AceDB and type(AceDB.db_registry) == "table" then
		for db in pairs(AceDB.db_registry) do
			switchDb(db)
		end
	end
end

local function addonSavedVarNames(addonName)
	local names = {}
	if not addonName then
		return names
	end
	for _, field in ipairs({ "SavedVariables", "SavedVariablesPerCharacter" }) do
		local list = splitVars(getAddOnMetadata(addonName, field))
		for i = 1, #list do
			names[#names + 1] = list[i]
		end
	end
	return names
end

-- Platynator builds nameplate pools from DESIGN_ASSIGNMENTS at ADDON_LOADED.
-- Injecting PLATYNATOR_* after that leaves style keys like _deer$$1$$1
-- with no preallocated displays.
local DISPLAY_VARS = {
	PLATYNATOR_CONFIG = true,
	PLATYNATOR_CURRENT_PROFILE = true,
	PLATYNATOR_LAST_INSTANCE = true,
}
local displayAddonsSettled = false

local BAGANATOR_OWNED = {
	BAGANATOR_CONFIG = true,
	BAGANATOR_CURRENT_PROFILE = true,
	SYNDICATOR_CONFIG = true,
}

local function baganatorLiveLooksSaved()
	local live = rawget(_G, "BAGANATOR_CONFIG")
	if type(live) ~= "table" or type(live.Profiles) ~= "table" then
		return false
	end
	local pname = rawget(_G, "BAGANATOR_CURRENT_PROFILE")
	local prof = (type(pname) == "string" and live.Profiles[pname]) or live.Profiles.DEFAULT
	return type(prof) == "table" and (prof.seen_welcome or 0) >= 1
end

local function injectOne(name, value, replace)
	if value == nil or SKIP[name] or isCacheName(name) or isUnsafeGlobal(name) or PROFILE_SKIP_VARS[name] then
		return false
	end
	if displayAddonsSettled and DISPLAY_VARS[name] then
		return false
	end
	-- Native Baganator.lua loaded with real settings. Replacing it with the
	-- last /flf snapshot made bag options look like they never saved.
	if BAGANATOR_OWNED[name] and not snapshotPrefer[name] and baganatorLiveLooksSaved() then
		if name == "BAGANATOR_CURRENT_PROFILE" then
			local live = rawget(_G, name)
			if type(live) == "string" and live ~= "" then
				return false
			end
		else
			local live = rawget(_G, name)
			if type(live) == "table" and next(live) ~= nil then
				return false
			end
		end
	end
	local dest = _G[name]
	if isAceAddonObject(dest) then
		dest = dest.sv
	end
	if type(dest) == "table" and type(value) == "table" then
		if replace then
			wipeMerge(dest, value)
		else
			mergeInto(dest, value)
		end
		aliasForeverNames(dest)
	else
		dest = copyClean(value)
		_G[name] = dest
		if type(dest) == "table" then
			aliasForeverNames(dest)
		end
	end
	if type(dest) == "table" then
		rehydrateShadow(name, dest)
	end
	return true
end

local function injectVars(opts)
	opts = opts or {}
	local vars = ForeverLayoutFixDB.vars
	if type(vars) ~= "table" then
		return 0
	end
	local replace = opts.replace == true
	local count = 0
	for name, value in pairs(vars) do
		local ok, err = pcall(function()
			if injectOne(name, value, replace) then
				count = count + 1
			end
		end)
		if not ok then
			dbg("inject failed " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	pcall(bindAceSavedVars)
	return count
end

local function injectAddonVars(addonName, opts)
	opts = opts or {}
	local vars = ForeverLayoutFixDB.vars
	if type(vars) ~= "table" or not addonName then
		return 0
	end
	local replace = opts.replace ~= false
	local count = 0
	local names = addonSavedVarNames(addonName)
	for i = 1, #names do
		local name = names[i]
		local ok, err = pcall(function()
			if injectOne(name, vars[name], replace) then
				count = count + 1
			end
		end)
		if not ok then
			dbg("inject failed " .. tostring(name) .. ": " .. tostring(err))
		end
	end
	if count > 0 then
		pcall(bindAceSavedVars)
	end
	return count
end

local function getRXP()
	local ace = LibStub and LibStub("AceAddon-3.0", true)
	return ace and ace:GetAddon("RXPGuides", true)
end

local function macroAccountCap()
	if MAX_ACCOUNT_MACROS and MAX_ACCOUNT_MACROS > 0 then
		return MAX_ACCOUNT_MACROS
	end
	return 120
end

local function macroCharCap()
	if MAX_CHARACTER_MACROS and MAX_CHARACTER_MACROS > 0 then
		return MAX_CHARACTER_MACROS
	end
	return 30
end

local function readMacro(index)
	if C_Macro and C_Macro.GetMacroInfo then
		local a, b, c = C_Macro.GetMacroInfo(index)
		if type(a) == "table" and a.name then
			return a.name, a.icon, a.body
		end
		if a then
			return a, b, c
		end
	end
	if GetMacroInfo then
		return GetMacroInfo(index)
	end
end

local function macroCount(m)
	if type(m) ~= "table" then
		return 0
	end
	local n = 0
	if type(m.account) == "table" then
		n = n + #m.account
	end
	if type(m.character) == "table" then
		n = n + #m.character
	end
	return n
end

local function mapCount(t)
	if type(t) ~= "table" then
		return 0
	end
	local n = 0
	for _ in pairs(t) do
		n = n + 1
	end
	return n
end

local function keepIfRicher(old, new, nNew, nOld)
	if nNew > 0 then
		return new
	end
	if nOld and nOld > 0 then
		return old
	end
	return new
end

local UI_CVARS = {
	"alwaysShowActionBars",
	"lockActionBars",
	"countdownForCooldowns",
	"ActionButtonUseKeyDown",
	"autoPushSpellToActionBar",
	"secureAbilityToggle",
	"autoSelfCast",
	"autoDismount",
	"autoClearAFK",
	"autoLootDefault",
	"lootUnderMouse",
	"interactOnLeftClick",
	"deselectOnClick",
	"showTargetOfTarget",
	"showTutorials",
	"UberTooltips",
	"alwaysCompareItems",
	"UnitNameOwn",
	"UnitNameNPC",
	"UnitNamePlayerGuild",
	"UnitNamePlayerPVPTitle",
	"nameplateShowEnemies",
	"nameplateShowEnemyMinions",
	"nameplateShowFriends",
	"nameplateShowFriendlyMinions",
	"nameplateShowAll",
	"nameplateMaxDistance",
	"nameplateOtherTopInset",
	"nameplateLargeTopInset",
	"cameraDistanceMaxZoomFactor",
	"cameraSmoothStyle",
	"ffxGlow",
	"ffxDeath",
	"ffxNether",
	"showSpenderFeedback",
	"doNotFlashLowHealthWarning",
	"findYourselfMode",
	"SoftTargetInteract",
	"SoftTargetEnemy",
	"SoftTargetFriend",
}

local function saveBlizzardUI()
	local db = ForeverLayoutFixDB
	pcall(function()
		local maxAcc = macroAccountCap()
		local maxChar = macroCharCap()
		local accN, charN = 0, 0
		if GetNumMacros then
			accN, charN = GetNumMacros()
			accN, charN = accN or 0, charN or 0
		end
		if accN < 1 then
			accN = maxAcc
		end
		if charN < 1 then
			charN = maxChar
		end
		local macros = { account = {}, character = {} }
		for i = 1, accN do
			local name, icon, body = readMacro(i)
			if name then
				macros.account[#macros.account + 1] = { name = name, icon = icon, body = body or "" }
			end
		end
		for i = 1, charN do
			local name, icon, body = readMacro(maxAcc + i)
			if name then
				macros.character[#macros.character + 1] = { name = name, icon = icon, body = body or "" }
			end
		end
		-- Logout/reload can report 0 macros after the game has already torn them
		-- down. Never replace a good snapshot with an empty one.
		db.macros = keepIfRicher(db.macros, macros, macroCount(macros), macroCount(db.macros))
	end)
	pcall(function()
		local slots = {}
		for slot = 1, 120 do
			local occupied = true
			if HasAction then
				occupied = HasAction(slot)
			end
			if occupied and GetActionInfo then
				local aType, id, subType = GetActionInfo(slot)
				if aType then
					slots[slot] = {
						type = aType,
						id = id,
						subType = subType,
						text = GetActionText and GetActionText(slot) or nil,
					}
				end
			end
		end
		db.actionBars = keepIfRicher(db.actionBars, slots, mapCount(slots), mapCount(db.actionBars))
		if GetActionBarPage then
			db.actionBarPage = GetActionBarPage()
		end
		if GetActionBarToggles then
			local a, b, c, d = GetActionBarToggles()
			db.actionBarToggles = { a, b, c, d }
		end
	end)
	pcall(function()
		local cvars = {}
		for i = 1, #UI_CVARS do
			local key = UI_CVARS[i]
			if GetCVar then
				local v = GetCVar(key)
				if v ~= nil then
					cvars[key] = v
				end
			end
		end
		db.cvars = keepIfRicher(db.cvars, cvars, mapCount(cvars), mapCount(db.cvars))
	end)
	pcall(function()
		if not GetNumBindings or not GetBinding then
			return
		end
		local binds = {}
		for i = 1, GetNumBindings() do
			local nret = select("#", GetBinding(i))
			local command, a, b, c = GetBinding(i)
			local key1, key2
			if nret >= 4 then
				key1, key2 = b, c
			else
				key1, key2 = a, b
			end
			if command and (key1 or key2) then
				binds[#binds + 1] = { command = command, key1 = key1, key2 = key2 }
			end
		end
		db.bindings = keepIfRicher(db.bindings, binds, #binds, type(db.bindings) == "table" and #db.bindings or 0)
		if GetCurrentBindingSet then
			db.bindingSet = GetCurrentBindingSet()
		end
	end)
	pcall(function()
		if not C_EditMode or not C_EditMode.GetLayouts then
			return
		end
		local info = C_EditMode.GetLayouts()
		if type(info) ~= "table" then
			return
		end
		db.editMode = copyClean(info)
		if EditModeManagerFrame and EditModeManagerFrame.GetActiveLayoutInfo then
			local active = EditModeManagerFrame:GetActiveLayoutInfo()
			if active and active.layoutName then
				db.editMode.activeName = active.layoutName
			end
		end
		if C_EditMode.ConvertLayoutInfoToString and type(info.layouts) == "table" then
			local encoded = {}
			for i = 1, #info.layouts do
				local layout = info.layouts[i]
				if type(layout) == "table" then
					local ok, s = pcall(C_EditMode.ConvertLayoutInfoToString, layout)
					if ok and type(s) == "string" and s ~= "" then
						encoded[#encoded + 1] = { name = layout.layoutName, data = s }
					end
				end
			end
			if #encoded > 0 then
				db.editMode.encoded = encoded
			end
		end
	end)
end

local function findMacroIndex(name, perChar)
	if not name then
		return
	end
	local maxAcc = macroAccountCap()
	local accN, charN = maxAcc, macroCharCap()
	if GetNumMacros then
		local a, c = GetNumMacros()
		if (a or 0) > 0 then
			accN = a
		end
		if (c or 0) > 0 then
			charN = c
		end
	end
	if perChar then
		for i = 1, charN do
			local n = readMacro(maxAcc + i)
			if n == name then
				return maxAcc + i
			end
		end
	else
		for i = 1, accN do
			local n = readMacro(i)
			if n == name then
				return i
			end
		end
	end
end

local function restoreMacros()
	local macros = ForeverLayoutFixDB.macros
	if type(macros) ~= "table" then
		return 0
	end
	local n = 0
	local function apply(list, perChar)
		if type(list) ~= "table" then
			return
		end
		for i = 1, #list do
			local m = list[i]
			if type(m) == "table" and m.name then
				local idx = findMacroIndex(m.name, perChar)
				local icon = m.icon or "INV_MISC_QUESTIONMARK"
				if idx then
					local edit = (C_Macro and C_Macro.EditMacro) or EditMacro
					if edit then
						pcall(edit, idx, m.name, icon, m.body or "")
						n = n + 1
					end
				elseif CreateMacro or (C_Macro and C_Macro.CreateMacro) then
					local create = (C_Macro and C_Macro.CreateMacro) or CreateMacro
					local ok = pcall(create, m.name, icon, m.body or "", perChar)
					if not ok then
						ok = pcall(create, m.name, icon, m.body or "", perChar and 1 or nil)
					end
					if not ok and type(icon) == "number" then
						ok = pcall(create, m.name, "INV_MISC_QUESTIONMARK", m.body or "", perChar)
					end
					if ok then
						n = n + 1
					end
				end
			end
		end
	end
	apply(macros.account, false)
	apply(macros.character, true)
	return n
end

local function cursorBusy()
	if not GetCursorInfo then
		return true
	end
	return GetCursorInfo() ~= nil
end

local function tryPickup(fn, ...)
	if not fn then
		return false
	end
	pcall(ClearCursor)
	local ok = pcall(fn, ...)
	return ok and cursorBusy()
end

local function pickupSavedAction(info)
	if type(info) ~= "table" or not info.type then
		return false
	end
	local t, id = info.type, info.id
	if t == "macro" then
		local idx
		if type(info.text) == "string" then
			idx = findMacroIndex(info.text, false) or findMacroIndex(info.text, true)
		end
		if idx then
			return tryPickup(PickupMacro, idx)
		end
		if info.text then
			return tryPickup(PickupMacro, info.text)
		end
		if id then
			return tryPickup(PickupMacro, id)
		end
	elseif t == "spell" or t == "companion" then
		if id and C_Spell and C_Spell.PickupSpell and tryPickup(C_Spell.PickupSpell, id) then
			return true
		end
		if id and tryPickup(PickupSpell, id) then
			return true
		end
		if id and GetSpellInfo then
			local name = GetSpellInfo(id)
			if name and tryPickup(PickupSpell, name) then
				return true
			end
		end
	elseif t == "item" then
		return tryPickup(PickupItem, id)
	elseif t == "equipmentset" then
		return tryPickup(C_EquipmentSet and C_EquipmentSet.PickupEquipmentSet, id)
	elseif t == "summonmount" or t == "mount" then
		return tryPickup(C_MountJournal and C_MountJournal.Pickup, id)
	end
	return false
end

local function restoreActionBars()
	if InCombatLockdown and InCombatLockdown() then
		return 0, "in combat"
	end
	local slots = ForeverLayoutFixDB.actionBars
	if type(slots) ~= "table" then
		return 0
	end
	if not PlaceAction then
		return 0
	end
	local n = 0
	for slot = 1, 120 do
		pcall(ClearCursor)
		local info = slots[slot]
		if info then
			if pickupSavedAction(info) then
				if pcall(PlaceAction, slot) then
					n = n + 1
				end
			end
		elseif HasAction and HasAction(slot) and PickupAction then
			pcall(PickupAction, slot)
			pcall(ClearCursor)
		end
		pcall(ClearCursor)
	end
	if ForeverLayoutFixDB.actionBarToggles and SetActionBarToggles then
		local t = ForeverLayoutFixDB.actionBarToggles
		pcall(SetActionBarToggles, t[1], t[2], t[3], t[4])
	end
	if ForeverLayoutFixDB.actionBarPage and ChangeActionBarPage then
		pcall(ChangeActionBarPage, ForeverLayoutFixDB.actionBarPage)
	end
	return n
end

local function restoreCVars()
	local cvars = ForeverLayoutFixDB.cvars
	if type(cvars) ~= "table" or not SetCVar then
		return 0
	end
	local n = 0
	for k, v in pairs(cvars) do
		if pcall(SetCVar, k, v) then
			n = n + 1
		end
	end
	return n
end

local function restoreBindings()
	local binds = ForeverLayoutFixDB.bindings
	if type(binds) ~= "table" or not SetBinding then
		return 0
	end
	local n = 0
	for i = 1, #binds do
		local b = binds[i]
		if type(b) == "table" and b.command then
			if b.key1 then
				pcall(SetBinding, b.key1, b.command)
			end
			if b.key2 then
				pcall(SetBinding, b.key2, b.command)
			end
			n = n + 1
		end
	end
	if n > 0 and SaveBindings and GetCurrentBindingSet then
		pcall(SaveBindings, ForeverLayoutFixDB.bindingSet or GetCurrentBindingSet())
	end
	return n
end

local function restoreEditMode()
	local saved = ForeverLayoutFixDB.editMode
	if type(saved) ~= "table" or not C_EditMode or not C_EditMode.GetLayouts then
		return false
	end
	local ok, current = pcall(C_EditMode.GetLayouts)
	if not ok or type(current) ~= "table" or type(current.layouts) ~= "table" then
		return false
	end
	local wantName = saved.activeName
	if not wantName and type(saved.layouts) == "table" and type(saved.activeLayout) == "number" then
		local rec = saved.layouts[saved.activeLayout]
		wantName = rec and rec.layoutName
	end
	if wantName and EditModeManagerFrame and EditModeManagerFrame.GetActiveLayoutInfo then
		local active = EditModeManagerFrame:GetActiveLayoutInfo()
		if active and active.layoutName == wantName then
			return true
		end
	end
	local have = {}
	for i = 1, #current.layouts do
		local n = current.layouts[i] and current.layouts[i].layoutName
		if n then
			have[n] = i
		end
	end
	local changed = false
	if type(saved.encoded) == "table" and C_EditMode.ConvertStringToLayoutInfo then
		for i = 1, #saved.encoded do
			local enc = saved.encoded[i]
			if type(enc) == "table" and enc.data and enc.name and not have[enc.name] then
				local decodedOk, layout = pcall(C_EditMode.ConvertStringToLayoutInfo, enc.data)
				if decodedOk and type(layout) == "table" then
					layout.layoutName = layout.layoutName or enc.name
					current.layouts[#current.layouts + 1] = layout
					have[enc.name] = #current.layouts
					changed = true
				end
			end
		end
	end
	if type(saved.layouts) == "table" then
		for i = 1, #saved.layouts do
			local layout = saved.layouts[i]
			if type(layout) == "table" and layout.layoutName and not have[layout.layoutName] then
				current.layouts[#current.layouts + 1] = copyClean(layout)
				have[layout.layoutName] = #current.layouts
				changed = true
			end
		end
	end
	if changed and C_EditMode.SaveLayouts then
		pcall(C_EditMode.SaveLayouts, current)
		ok, current = pcall(C_EditMode.GetLayouts)
	end
	if wantName and C_EditMode.SetActiveLayout then
		if EditModeManagerFrame and EditModeManagerFrame.GetLayouts then
			local layouts = EditModeManagerFrame:GetLayouts()
			if type(layouts) == "table" then
				for index, layout in ipairs(layouts) do
					if layout.layoutName == wantName then
						pcall(C_EditMode.SetActiveLayout, index)
						return true
					end
				end
			end
		end
		if type(current) == "table" and type(current.layouts) == "table" then
			for i = 1, #current.layouts do
				if current.layouts[i] and current.layouts[i].layoutName == wantName then
					pcall(C_EditMode.SetActiveLayout, i + 2)
					return true
				end
			end
		end
	elseif type(saved.activeLayout) == "number" and C_EditMode.SetActiveLayout then
		pcall(C_EditMode.SetActiveLayout, saved.activeLayout)
		return true
	end
	return false
end

local function restoreBlizzardUI(opts)
	opts = opts or {}
	local macros = restoreMacros()
	local cvars = restoreCVars()
	local binds = restoreBindings()
	local edit = restoreEditMode()
	local bars, barErr = 0, nil
	if opts.bars then
		bars, barErr = restoreActionBars()
	end
	return { macros = macros, cvars = cvars, binds = binds, edit = edit, bars = bars, barErr = barErr }
end

local flushSexyMap, applySexyMapLayout, applyXLootLayout

local function saveLive()
	local db = ForeverLayoutFixDB
	pcall(flushSexyMap)
	if SexyMapNS then
		if SexyMapNS.shapes and SexyMapNS.shapes.GetShape then
			db.sexyMapShape = SexyMapNS.shapes:GetShape()
		end
		if SexyMapNS.borders and SexyMapNS.borders.db then
			db.sexyMapBorders = copyClean(SexyMapNS.borders.db)
		end
		if SexyMapNS.core and SexyMapNS.core.db then
			db.sexyMapCore = copyClean(SexyMapNS.core.db)
		end
	end
	local rxp = getRXP()
	local data = type(RXPCData) == "table" and RXPCData or nil
	local guide = rxp and rxp.currentGuide
	local name = rxp and rxp.currentGuideName
	if (not name or name == "") and guide and not guide.empty then
		name = guide.name
	end
	if (not name or name == "") and data then
		name = data.currentGuideName
	end
	-- Logout tears RXP down first. Never blank a good guide snapshot.
	if type(name) == "string" and name ~= "" then
		db.rxpName = name
	end
	db.rxpGroup = (guide and not guide.empty and guide.group) or (data and data.currentGuideGroup) or db.rxpGroup
	db.rxpKey = (guide and not guide.empty and guide.key) or db.rxpKey
	db.rxpStep = (data and data.currentStep) or (rxp and rxp.currentStep) or db.rxpStep
	db.rxpStepId = (data and data.currentStepId) or db.rxpStepId
	local rxpFrame = (rxp and rxp.RXPFrame) or _G.RXPFrame
	local rxpProfile = rxp and rxp.settings and rxp.settings.profile
	local scale = (type(rxpProfile) == "table" and rxpProfile.windowScale)
		or (rxpFrame and rxpFrame.GetScale and rxpFrame:GetScale())
		or nil
	local height = (type(rxpProfile) == "table" and rxpProfile.frameHeight)
		or (rxpFrame and rxpFrame.GetHeight and rxpFrame:GetHeight())
		or nil
	if type(scale) == "number" or type(height) == "number" then
		local prev = type(db.rxpWindow) == "table" and db.rxpWindow or {}
		db.rxpWindow = {
			scale = type(scale) == "number" and scale or prev.scale,
			height = type(height) == "number" and height or prev.height,
		}
	end
	saveBlizzardUI()
end

local function restoreLive()
	pcall(applySexyMapLayout)
	pcall(function()
		if SexyMapNS then
			if ForeverLayoutFixDB.sexyMapShape and SexyMapNS.shapes and SexyMapNS.shapes.ApplyShape then
				SexyMapNS.shapes:ApplyShape(ForeverLayoutFixDB.sexyMapShape)
			end
			if type(ForeverLayoutFixDB.sexyMapBorders) == "table" and SexyMapNS.borders and SexyMapNS.borders.db then
				local src = ForeverLayoutFixDB.sexyMapBorders
				local dst = SexyMapNS.borders.db
				if src.borders then
					dst.borders = copyClean(src.borders)
				end
				if src.backdrop then
					dst.backdrop = copyClean(src.backdrop)
				end
				dst.hideBlizzard = src.hideBlizzard
				dst.applyPreset = src.applyPreset
				if SexyMapNS.borders.ApplySettings then
					SexyMapNS.borders:ApplySettings()
				elseif SexyMapNS.borders.UpdateBorder then
					SexyMapNS.borders:UpdateBorder()
				end
			end
			if type(ForeverLayoutFixDB.sexyMapCore) == "table" and SexyMapNS.core and SexyMapNS.core.db then
				for k, v in pairs(ForeverLayoutFixDB.sexyMapCore) do
					SexyMapNS.core.db[k] = v
				end
				local c = SexyMapNS.core.db
				if c.point then
					Minimap:ClearAllPoints()
					Minimap:SetPoint(c.point, UIParent, c.relpoint or c.point, c.x or 0, c.y or 0)
				end
				if c.scale then
					Minimap:SetScale(c.scale)
				end
			end
		end
	end)
	local function restoreBaganator()
		local vars = ForeverLayoutFixDB.vars
		if snapshotPrefer.BAGANATOR_CURRENT_PROFILE and type(vars) == "table" and type(vars.BAGANATOR_CURRENT_PROFILE) == "string" then
			_G.BAGANATOR_CURRENT_PROFILE = vars.BAGANATOR_CURRENT_PROFILE
		end
		local bagCfg = rawget(_G, "BAGANATOR_CONFIG") or (type(vars) == "table" and vars.BAGANATOR_CONFIG)
		if type(bagCfg) ~= "table" or type(bagCfg.Profiles) ~= "table" then
			return
		end
		local pname = (type(BAGANATOR_CURRENT_PROFILE) == "string" and BAGANATOR_CURRENT_PROFILE)
			or (type(vars) == "table" and vars.BAGANATOR_CURRENT_PROFILE)
			or "DEFAULT"
		local profile = bagCfg.Profiles[pname] or bagCfg.Profiles.DEFAULT
		if profile and (profile.seen_welcome or 0) >= 1 and Baganator_WelcomeFrame then
			Baganator_WelcomeFrame:Hide()
		end
	end
	restoreBaganator()
	pcall(function()
		bindAceSavedVars({ switchProfile = true })
	end)
	pcall(applyXLootLayout)
	pcall(function()
		local rxp = getRXP()
		local data = _G.RXPCData
		local snap = ForeverLayoutFixDB.vars and ForeverLayoutFixDB.vars.RXPCData
		if type(snap) == "table" then
			if type(data) ~= "table" then
				_G.RXPCData = copyClean(snap)
				data = _G.RXPCData
			else
				wipeMerge(data, snap)
			end
		end
		local name = ForeverLayoutFixDB.rxpName or (data and data.currentGuideName)
		local group = ForeverLayoutFixDB.rxpGroup or (data and data.currentGuideGroup)
		local key = ForeverLayoutFixDB.rxpKey
		if rxp and type(name) == "string" and name ~= "" then
			if data then
				data.currentGuideName = name
				data.currentGuideGroup = group
				if ForeverLayoutFixDB.rxpStep then
					data.currentStep = ForeverLayoutFixDB.rxpStep
				end
				if ForeverLayoutFixDB.rxpStepId then
					data.currentStepId = ForeverLayoutFixDB.rxpStepId
				end
			end
			local guide
			if rxp.GetGuideTable and group then
				guide = rxp.GetGuideTable(group, name)
			end
			if not guide and rxp.guides then
				for _, g in pairs(rxp.guides) do
					if (key and g.key == key) or g.name == name then
						guide = g
						break
					end
				end
			end
			if guide and rxp.LoadGuide then
				rxp:LoadGuide(guide, true)
			elseif rxp.LoadGuideTable and group then
				rxp:LoadGuideTable(group, name)
			end
		end
		local profile = rxp and rxp.settings and rxp.settings.profile
		if rxp and type(profile) == "table" then
			local custom = profile.customTheme
			if rxp.RegisterTheme and type(custom) == "table" and type(custom.name) == "string" and custom.name ~= "" and type(custom.author) == "string" then
				rxp:RegisterTheme(custom)
			end
			local wantTheme = profile.activeTheme
			local haveTheme = rxp.activeTheme and (rxp.activeTheme.name or rxp.activeTheme.displayName)
			if rxp.LoadActiveTheme and wantTheme and wantTheme ~= haveTheme then
				rxp:LoadActiveTheme()
				if rxp.ReloadTheme then
					rxp:ReloadTheme()
				end
			end
			if rxp.settings and rxp.settings.LoadFramePositions then
				rxp.settings:LoadFramePositions()
			end
			if rxp.tracker and rxp.tracker.UpdateLevelSplits then
				rxp.tracker:UpdateLevelSplits("full")
			end
		elseif rxp and rxp.settings and rxp.settings.LoadFramePositions then
			rxp.settings:LoadFramePositions()
		end
	end)
	pcall(function()
		local rxp = getRXP()
		local frame = (rxp and rxp.RXPFrame) or _G.RXPFrame
		local profile = rxp and rxp.settings and rxp.settings.profile
		local win = ForeverLayoutFixDB.rxpWindow
		local scale = (type(win) == "table" and win.scale) or (type(profile) == "table" and profile.windowScale)
		local height = (type(win) == "table" and win.height) or (type(profile) == "table" and profile.frameHeight)
		if type(profile) == "table" then
			if type(scale) == "number" then
				profile.windowScale = scale
			end
			if type(height) == "number" then
				profile.frameHeight = height
			end
		end
		if frame then
			if type(scale) == "number" and frame.SetScale then
				frame:SetScale(scale)
			end
			if type(height) == "number" and height >= 10 and frame.SetHeight then
				frame:SetHeight(height)
			end
		end
	end)
end

local function applyDetailsLayout()
	local Details = detailsAddon()
	if not Details or type(Details.ApplyProfile) ~= "function" then
		return
	end
	local snap = ForeverLayoutFixDB.vars
	if type(snap) ~= "table" then
		return
	end
	if snap._detalhes_global ~= nil then
		pcall(injectOne, "_detalhes_global", snap._detalhes_global, true)
	end
	if snap._detalhes_database ~= nil then
		pcall(injectOne, "_detalhes_database", snap._detalhes_database, true)
	end
	if snap.ThreatForeverDB ~= nil then
		pcall(injectOne, "ThreatForeverDB", snap.ThreatForeverDB, true)
	end
	if snap.DetailsTinyThreatDB ~= nil then
		pcall(injectOne, "DetailsTinyThreatDB", snap.DetailsTinyThreatDB, true)
	end
	local glob = rawget(_G, "_detalhes_global")
	local charDB = rawget(_G, "_detalhes_database")
	local want
	if type(snap._detalhes_database) == "table" then
		want = snap._detalhes_database.active_profile
	end
	if (type(want) ~= "string" or want == "") and type(charDB) == "table" then
		want = charDB.active_profile
	end
	local profiles = type(glob) == "table" and glob.__profiles
	if (type(want) ~= "string" or want == "" or type(profiles) ~= "table" or type(profiles[want]) ~= "table") and type(profiles) == "table" then
		want = nil
		for pname, prof in pairs(profiles) do
			if type(prof) == "table" and type(prof.instances) == "table" and #prof.instances > 0 then
				want = pname
				break
			end
		end
	end
	if type(want) ~= "string" or want == "" then
		return
	end
	if type(charDB) == "table" then
		charDB.active_profile = want
	end
	-- bNoSave: never write this character's empty windows over the saved profile.
	Details:ApplyProfile(want, true)
end

local function restoreProfileAddons(doRefresh)
	pcall(function()
		if type(MSUF_GlobalDB) == "table" then
			aliasForeverNames(MSUF_GlobalDB)
		end
		local want = ForeverLayoutFixDB.vars and ForeverLayoutFixDB.vars.MSUF_ActiveProfile
		if type(want) == "string" and want ~= ""
			and type(MSUF_GlobalDB) == "table"
			and type(MSUF_GlobalDB.profiles) == "table"
			and type(MSUF_GlobalDB.profiles[want]) == "table" then
			MSUF_GlobalDB.char = MSUF_GlobalDB.char or {}
			local keys = foreverNameKeys()
			for i = 1, #keys do
				local c = MSUF_GlobalDB.char[keys[i]]
				if type(c) ~= "table" then
					MSUF_GlobalDB.char[keys[i]] = { activeProfile = want }
				elseif type(c.activeProfile) ~= "string" or c.activeProfile == "" or c.activeProfile == "Default" then
					c.activeProfile = want
				end
			end
		end
		if type(MSUF_InitProfiles) == "function" then
			MSUF_InitProfiles()
		end
		local snap = ForeverLayoutFixDB.vars and ForeverLayoutFixDB.vars.MSUF_DB
		if type(snap) == "table" and type(MSUF_DB) == "table" and substance(MSUF_DB) < substance(snap) then
			mergeInto(MSUF_DB, snap)
		end
	end)
	pcall(function()
		if type(EllesmereUIDB) ~= "table" then
			return
		end
		aliasForeverNames(EllesmereUIDB)
		local eui = _G.EllesmereUI
		local registry = eui and eui.Lite and eui.Lite._dbRegistry
		local active = EllesmereUIDB.activeProfile or "Default"
		local pdata = EllesmereUIDB.profiles and EllesmereUIDB.profiles[active]
		local addons = pdata and pdata.addons
		if type(registry) == "table" and type(addons) == "table" then
			for _, dbo in ipairs(registry) do
				if dbo.folder and type(addons[dbo.folder]) == "table" then
					dbo.sv = EllesmereUIDB
					dbo.profile = addons[dbo.folder]
					dbo._profileName = active
				end
			end
		end
		if doRefresh and eui and type(eui.RefreshAllAddons) == "function" then
			eui.RefreshAllAddons(true)
		end
	end)
	pcall(applyDetailsLayout)
end

for name in pairs(ForeverLayoutFixDB.varNames) do
	if not isUnsafeGlobal(name) then
		discovered[name] = true
	end
end

local function copyPoint(frame)
	if not frame or not frame.GetPoint then
		return nil
	end
	local n = frame:GetNumPoints()
	if not n or n < 1 then
		return nil
	end
	local p, rel, rp, x, y = frame:GetPoint(1)
	if not p then
		return nil
	end
	local relName = rel and rel.GetName and rel:GetName()
	if not relName or relName == "" then
		relName = "UIParent"
	end
	return {
		p = p,
		rel = relName,
		rp = rp or p,
		x = x or 0,
		y = y or 0,
	}
end

local function applyPoint(frame, pt)
	if not frame or not pt or not pt.p then
		return false
	end
	local rel = _G[pt.rel or "UIParent"] or UIParent
	frame:ClearAllPoints()
	frame:SetPoint(pt.p, rel, pt.rp or pt.p, pt.x or 0, pt.y or 0)
	return true
end

local function findIssueReporter()
	local names = {
		"PTRIssueReporter",
		"PTR_IssueReporter",
		"IssueReporter",
		"IssueReporterFrame",
		"PTRFeedbackReporter",
		"PTRFeedbackFrame",
		"Blizzard_PTRIssueReporter",
		"PTRBugReporter",
		"BugReporterFrame",
	}
	for i = 1, #names do
		local f = _G[names[i]]
		if f and f.SetPoint then
			return f, names[i]
		end
	end
end

local function mbbFrame()
	return _G.MinimapButtonButtonButton
end

local SEXYMAP_MODULES = {
	"core", "borders", "buttons", "clock", "coordinates", "movers", "zonetext", "hudmap", "ping",
}

local function sexyMapCharKey()
	local n, r = UnitName("player"), GetRealmName()
	if n and r then
		return n .. "-" .. r
	end
end

local function sexyMapSlot(sv, create)
	if type(sv) ~= "table" then
		return
	end
	local try = aceCharKeyVariants(UnitName("player"), GetRealmName())
	for i = 1, #try do
		local slot = sv[try[i]]
		if type(slot) == "string" then
			sv.global = type(sv.global) == "table" and sv.global or {}
			return sv.global
		elseif type(slot) == "table" then
			return slot
		end
	end
	if not create then
		return
	end
	local char = sexyMapCharKey()
	if not char then
		return
	end
	sv[char] = {}
	return sv[char]
end

local function pickSexyMapSource(sv)
	if type(sv) ~= "table" then
		return
	end
	local best, bestn
	local function consider(v)
		if type(v) ~= "table" then
			return
		end
		local s = substance(v, 8000)
		if not bestn or s > bestn then
			best, bestn = v, s
		end
	end
	local try = aceCharKeyVariants(UnitName("player"), GetRealmName())
	local savedP = ForeverLayoutFixDB.lastSavePlayer
	local savedR = ForeverLayoutFixDB.lastSaveRealm or GetRealmName()
	if type(savedP) == "string" and savedP ~= "" then
		local extra = aceCharKeyVariants(savedP, savedR)
		for i = 1, #extra do
			try[#try + 1] = extra[i]
		end
	end
	for i = 1, #try do
		local v = sv[try[i]]
		if type(v) == "string" then
			v = sv.global
		end
		consider(v)
	end
	if best then
		return best
	end
	for k, v in pairs(sv) do
		if k ~= "presets" and k ~= "global" and type(v) == "table" then
			consider(v)
		end
	end
	if (not bestn or bestn < 2) and type(sv.global) == "table" then
		return sv.global
	end
	return best
end

function flushSexyMap()
	local sv = rawget(_G, "SexyMap2DB")
	if type(sv) ~= "table" then
		_G.SexyMap2DB = {}
		sv = _G.SexyMap2DB
	end
	rememberName("SexyMap2DB")
	local sm = _G.SexyMapNS
	local slot = sexyMapSlot(sv, true)
	if type(slot) ~= "table" then
		return
	end
	if sm then
		for i = 1, #SEXYMAP_MODULES do
			local key = SEXYMAP_MODULES[i]
			local mod = sm[key]
			if type(mod) == "table" and type(mod.db) == "table" then
				slot[key] = copyClean(mod.db)
			end
		end
		if sm.shapes and sm.shapes.GetShape then
			slot.core = type(slot.core) == "table" and slot.core or {}
			slot.core.shape = sm.shapes:GetShape()
		end
	end
	local db = ForeverLayoutFixDB
	db.sexyMapProfile = copyClean(slot)
	if slot.core then
		db.sexyMapCore = copyClean(slot.core)
		db.sexyMapShape = slot.core.shape
	end
	if slot.borders then
		db.sexyMapBorders = copyClean(slot.borders)
	end
end

function applySexyMapLayout()
	local vars = ForeverLayoutFixDB.vars
	local sv = rawget(_G, "SexyMap2DB")
	if type(vars) == "table" and type(vars.SexyMap2DB) == "table" then
		if type(sv) ~= "table" then
			_G.SexyMap2DB = copyClean(vars.SexyMap2DB)
			sv = _G.SexyMap2DB
		else
			wipeMerge(sv, vars.SexyMap2DB)
		end
	end
	if type(sv) ~= "table" then
		return
	end
	local src = pickSexyMapSource(sv)
	local extra = ForeverLayoutFixDB.sexyMapProfile
	if type(extra) == "table" and substance(extra, 8000) > substance(src, 8000) then
		src = extra
	end
	if type(src) ~= "table" then
		return
	end
	local slot = sexyMapSlot(sv, true)
	if type(slot) == "table" and slot ~= src then
		wipeMerge(slot, src)
	end
	local sm = _G.SexyMapNS
	if not sm then
		return
	end
	local live = (type(slot) == "table" and slot) or src
	for i = 1, #SEXYMAP_MODULES do
		local key = SEXYMAP_MODULES[i]
		local mod = sm[key]
		if type(mod) == "table" and type(mod.db) == "table" and type(live[key]) == "table" then
			wipeMerge(mod.db, live[key])
		end
	end
	if type(live.core) == "table" and sm.core and type(sm.core.db) == "table" then
		wipeMerge(sm.core.db, live.core)
	end
	local shape = (sm.core and sm.core.db and sm.core.db.shape) or (live.core and live.core.shape)
	if shape and sm.shapes and sm.shapes.ApplyShape then
		sm.shapes:ApplyShape(shape)
	end
	if sm.borders and sm.borders.ApplySettings then
		sm.borders:ApplySettings()
	elseif sm.borders and sm.borders.UpdateBorder then
		sm.borders:UpdateBorder()
	end
end

function applyXLootLayout()
	local vars = ForeverLayoutFixDB.vars
	local src = type(vars) == "table" and vars.XLootADB
	local dest = rawget(_G, "XLootADB")
	if type(src) == "table" then
		if type(dest) ~= "table" then
			_G.XLootADB = copyClean(src)
			dest = _G.XLootADB
		else
			wipeMerge(dest, src)
		end
		aliasForeverNames(dest)
	end
	local x = _G.XLoot
	if type(x) ~= "table" then
		return
	end
	local AceDB = LibStub and LibStub("AceDB-3.0", true)
	if AceDB and type(AceDB.db_registry) == "table" then
		for db in pairs(AceDB.db_registry) do
			if type(db) == "table" and (db == x.db or (db.parent and db.parent == x.db)) then
				local pname, prof = pickSourceAceProfile(db.sv)
				if pname and type(db.SetProfile) == "function" then
					pcall(function()
						db:SetProfile(pname)
					end)
				end
				if type(db.profile) == "table" and type(prof) == "table" then
					wipeMerge(db.profile, copyClean(prof))
				end
			end
		end
	end
	if type(x.ApplyOptions) == "function" then
		x:ApplyOptions(true)
	elseif type(x.SetSkin) == "function" and x.opt and x.opt.skin then
		x:SetSkin(x.opt.skin)
	end
end

local function saveFrames()
	local db = ForeverLayoutFixDB
	local reporter = findIssueReporter()
	if reporter then
		db.issueReporter = copyPoint(reporter)
		if Blizzard_PTRIssueReporter_Saved then
			db.ptrX = Blizzard_PTRIssueReporter_Saved.x
			db.ptrY = Blizzard_PTRIssueReporter_Saved.y
		end
	end
	local mbb = mbbFrame()
	if mbb then
		db.mbb = copyPoint(mbb)
	end
	if SexyMapNS and Minimap then
		db.minimap = copyPoint(Minimap)
	else
		db.minimap = nil
	end
	local rxpF = (getRXP() and getRXP().RXPFrame) or _G.RXPFrame
	if rxpF then
		db.rxpFrame = copyPoint(rxpF)
	end
end

local function flushLiveAddonState()
	pcall(function()
		local rxp = getRXP()
		if rxp and rxp.settings and rxp.settings.SaveFramePositions then
			rxp.settings:SaveFramePositions()
		end
	end)
	pcall(function()
		local AceDB = LibStub and LibStub("AceDB-3.0", true)
		if not AceDB or type(AceDB.db_registry) ~= "table" then
			return
		end
		for db in pairs(AceDB.db_registry) do
			-- Include AceDB namespaces (XLoot Frame/Monitor/etc.). Skipping
			-- db.parent left those settings only in memory until logout.
			if type(db) == "table" and type(db.sv) == "table" and type(db.profile) == "table" then
				local pname = db.keys and db.keys.profile
				if type(pname) == "string" and pname ~= "" then
					db.sv.profiles = db.sv.profiles or {}
					if db.sv.profiles[pname] ~= db.profile then
						db.sv.profiles[pname] = db.profile
					end
				end
			end
		end
	end)
	pcall(function()
		local mbb = mbbFrame()
		if not mbb or not mbb.GetPoint then
			return
		end
		local p, rel, rp, x, y = mbb:GetPoint(1)
		if not p then
			return
		end
		local relName = (rel and rel.GetName and rel:GetName()) or "UIParent"
		_G.MinimapButtonButtonOptions = type(_G.MinimapButtonButtonOptions) == "table" and _G.MinimapButtonButtonOptions or {}
		_G.MinimapButtonButtonOptions.position = { p, relName, rp or p, x or 0, y or 0 }
	end)
	pcall(flushSexyMap)
	pcall(function()
		local Details = detailsAddon()
		if not Details then
			return
		end
		rememberDetailsNames()
		if type(Details.SaveProfile) == "function" then
			Details:SaveProfile()
		elseif type(Details.SaveLocalInstanceConfig) == "function" then
			Details:SaveLocalInstanceConfig()
		end
		local glob = rawget(_G, "_detalhes_global")
		if type(glob) ~= "table" then
			_G._detalhes_global = {}
			glob = _G._detalhes_global
		end
		if type(Details.default_global_data) == "table" then
			for key in pairs(Details.default_global_data) do
				if key ~= "__profiles" then
					local v = Details[key]
					local vt = type(v)
					if vt == "table" then
						glob[key] = copyClean(v)
					elseif vt ~= "function" and vt ~= "userdata" and vt ~= "thread" then
						glob[key] = v
					end
				end
			end
		end
		local charDB = rawget(_G, "_detalhes_database")
		if type(charDB) ~= "table" then
			_G._detalhes_database = {}
			charDB = _G._detalhes_database
		end
		if type(Details.default_player_data) == "table" then
			for key in pairs(Details.default_player_data) do
				if not DETAILS_CHAR_SKIP[key] then
					local v = Details[key]
					local vt = type(v)
					if vt == "table" then
						charDB[key] = copyClean(v)
					elseif vt ~= "function" and vt ~= "userdata" and vt ~= "thread" then
						charDB[key] = v
					end
				end
			end
		end
		if type(Details.active_profile) == "string" and Details.active_profile ~= "" then
			charDB.active_profile = Details.active_profile
		end
		local pluginDB = Details.plugin_database
		if type(pluginDB) == "table" then
			charDB.plugin_database = copyClean(pluginDB)
		end
	end)
end

local function saveAll(force)
	if type(ForeverLayoutFixDB.vars) == "table" then
		for k in pairs(ForeverLayoutFixDB.vars) do
			if isUnsafeGlobal(k) or PROFILE_SKIP_VARS[k] then
				ForeverLayoutFixDB.vars[k] = nil
			end
		end
		if ForeverLayoutFixDB.varNames then
			for k in pairs(ForeverLayoutFixDB.varNames) do
				if isUnsafeGlobal(k) or PROFILE_SKIP_VARS[k] then
					ForeverLayoutFixDB.varNames[k] = nil
				end
			end
		end
	end
	if varsAreEmpty() and not force then
		return 0
	end
	harvestAllAddOns()
	harvestScanGlobals()
	flushLiveAddonState()
	saveFrames()
	pcall(syncLeatrixToDB)
	saveLive()
	local n = snapshotVars(force)
	local db = ForeverLayoutFixDB
	db.lastSaveAt = time and time() or 0
	db.lastSaveCount = n
	db.lastSavePlayer = UnitName("player")
	db.lastSaveRealm = GetRealmName()
	db.lastSaveGuid = UnitGUID and UnitGUID("player") or nil
	db.lastSaveForce = force and true or false
	local acc = ForeverLayoutFixAccountDB
	if type(acc) == "table" then
		acc._lastSaveAt = db.lastSaveAt
		acc._lastSaveCount = n
		acc._lastSavePlayer = db.lastSavePlayer
		acc._lastSaveRealm = db.lastSaveRealm
	end
	return n
end

local function saveToProfile(name)
	name = sanitizeProfileName(name)
	if not name then
		return false, "Enter a profile name (1–40 characters)."
	end
	saveAll(true)
	if varsAreEmpty() then
		return false, "Nothing to save. Set up your addons, then save again."
	end
	savedProfileThisSession = true
	leatrixImportPending = false
	local acc = ensureProfileStore()
	acc.profiles[name] = {
		name = name,
		savedAt = time and time() or 0,
		savedPlayer = UnitName("player"),
		savedRealm = GetRealmName(),
		savedGuid = UnitGUID and UnitGUID("player") or nil,
		pack = scrubPack(copyClean(ForeverLayoutFixDB)),
	}
	acc.activeProfile = name
	ForeverLayoutFixDB.lastProfile = name
	return true, name
end

local function refreshActiveProfilePack()
	local acc = ensureProfileStore()
	if type(acc) ~= "table" or acc.profileEnabled == false then
		return false
	end
	local name = acc.activeProfile
	if type(name) ~= "string" or name == "" or type(acc.profiles) ~= "table" then
		return false
	end
	local rec = acc.profiles[name]
	if type(rec) ~= "table" then
		return false
	end
	if varsAreEmpty() then
		return false
	end
	local db = ForeverLayoutFixDB
	-- Logout only patches things that are not available until then (Leatrix).
	-- Replacing the whole pack here wiped RXP/macros after a good Save.
	if type(rec.pack) ~= "table" or type(rec.pack.vars) ~= "table" then
		rec.pack = scrubPack(copyClean(db))
	else
		rec.pack.vars = rec.pack.vars or {}
		if type(db.vars) == "table" then
			for _, varName in ipairs({ "LeaPlusDB", "LeaMapsDB", "BAGANATOR_CONFIG", "BAGANATOR_CURRENT_PROFILE", "SYNDICATOR_CONFIG", "_detalhes_global", "_detalhes_database", "ThreatForeverDB", "DetailsTinyThreatDB", "SexyMap2DB", "XLootADB" }) do
				if db.vars[varName] ~= nil then
					rec.pack.vars[varName] = copyClean(db.vars[varName])
				end
			end
		end
		rec.pack.macros = keepIfRicher(rec.pack.macros, db.macros, macroCount(db.macros), macroCount(rec.pack.macros))
		rec.pack.actionBars = keepIfRicher(rec.pack.actionBars, db.actionBars, mapCount(db.actionBars), mapCount(rec.pack.actionBars))
		rec.pack.cvars = keepIfRicher(rec.pack.cvars, db.cvars, mapCount(db.cvars), mapCount(rec.pack.cvars))
		rec.pack.bindings = keepIfRicher(rec.pack.bindings, db.bindings, type(db.bindings) == "table" and #db.bindings or 0, type(rec.pack.bindings) == "table" and #rec.pack.bindings or 0)
		if type(db.editMode) == "table" then
			rec.pack.editMode = copyClean(db.editMode)
		end
		if db.actionBarPage ~= nil then
			rec.pack.actionBarPage = db.actionBarPage
		end
		if type(db.actionBarToggles) == "table" then
			rec.pack.actionBarToggles = copyClean(db.actionBarToggles)
		end
		if type(db.rxpName) == "string" and db.rxpName ~= "" then
			rec.pack.rxpName = db.rxpName
			rec.pack.rxpGroup = db.rxpGroup
			rec.pack.rxpKey = db.rxpKey
			rec.pack.rxpStep = db.rxpStep
			rec.pack.rxpStepId = db.rxpStepId
		end
		if type(db.rxpWindow) == "table" and (type(db.rxpWindow.scale) == "number" or type(db.rxpWindow.height) == "number") then
			rec.pack.rxpWindow = copyClean(db.rxpWindow)
		end
		if type(db.rxpFrame) == "table" then
			rec.pack.rxpFrame = copyClean(db.rxpFrame)
		end
		if type(db.mbb) == "table" then
			rec.pack.mbb = copyClean(db.mbb)
		end
		if type(db.sexyMapProfile) == "table" then
			rec.pack.sexyMapProfile = copyClean(db.sexyMapProfile)
		end
		if type(db.sexyMapBorders) == "table" then
			rec.pack.sexyMapBorders = copyClean(db.sexyMapBorders)
		end
		if type(db.sexyMapCore) == "table" then
			rec.pack.sexyMapCore = copyClean(db.sexyMapCore)
		end
		if db.sexyMapShape ~= nil then
			rec.pack.sexyMapShape = db.sexyMapShape
		end
		if type(db.vars) == "table" then
			for _, varName in ipairs({ "_detalhes_global", "_detalhes_database", "ThreatForeverDB", "DetailsTinyThreatDB", "SexyMap2DB", "XLootADB" }) do
				if db.vars[varName] ~= nil then
					rec.pack.vars[varName] = copyClean(db.vars[varName])
				end
			end
		end
	end
	rec.savedAt = time and time() or 0
	rec.savedPlayer = UnitName("player")
	rec.savedRealm = GetRealmName()
	return true
end

local function renameProfile(oldName, newName)
	oldName = sanitizeProfileName(oldName)
	newName = sanitizeProfileName(newName)
	if not oldName or not newName then
		return false, "Invalid name."
	end
	local acc = ensureProfileStore()
	if type(acc.profiles[oldName]) ~= "table" then
		return false, "No profile named " .. oldName
	end
	if newName ~= oldName and acc.profiles[newName] then
		return false, "A profile named " .. newName .. " already exists."
	end
	if newName ~= oldName then
		acc.profiles[newName] = acc.profiles[oldName]
		acc.profiles[newName].name = newName
		acc.profiles[oldName] = nil
	end
	if acc.activeProfile == oldName then
		acc.activeProfile = newName
	end
	return true, newName
end

local function deleteProfile(name)
	name = sanitizeProfileName(name)
	local acc = ensureProfileStore()
	if not name or type(acc.profiles[name]) ~= "table" then
		return false, "No such profile."
	end
	acc.profiles[name] = nil
	if acc.activeProfile == name then
		local names = listProfileNames()
		acc.activeProfile = names[1]
		if not acc.activeProfile then
			acc.profileEnabled = false
		end
	end
	return true
end

local function setActiveProfile(name, enabled)
	name = sanitizeProfileName(name)
	local acc = ensureProfileStore()
	if not name or type(acc.profiles[name]) ~= "table" then
		return false, "No such profile."
	end
	acc.activeProfile = name
	ForeverLayoutFixDB.lastProfile = name
	return true, name
end

local function hookFrame(frame, key)
	if not frame or hooked[key] then
		return
	end
	hooked[key] = true
	if frame.HookScript then
		pcall(function()
			frame:HookScript("OnDragStop", saveFrames)
		end)
		pcall(function()
			frame:HookScript("OnMouseUp", saveFrames)
		end)
	end
end

local function applyFrames()
	local db = ForeverLayoutFixDB
	local reporter = findIssueReporter()
	if reporter then
		hookFrame(reporter, "reporter")
		if db.issueReporter then
			applyPoint(reporter, db.issueReporter)
		elseif db.ptrX and db.ptrY then
			reporter:ClearAllPoints()
			reporter:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", db.ptrX, db.ptrY)
		end
	end
	local mbb = mbbFrame()
	if mbb then
		hookFrame(mbb, "mbb")
		local pt = db.mbb
		if not pt then
			local opts = (db.vars and db.vars.MinimapButtonButtonOptions) or rawget(_G, "MinimapButtonButtonOptions")
			local pos = type(opts) == "table" and opts.position
			if type(pos) == "table" and (pos[1] or pos.p) then
				pt = {
					p = pos.p or pos[1],
					rel = pos.rel or (type(pos[2]) == "string" and pos[2]) or "UIParent",
					rp = pos.rp or pos[3],
					x = pos.x or pos[4],
					y = pos.y or pos[5],
				}
			end
		end
		if pt then
			applyPoint(mbb, pt)
		end
		local opts = (db.vars and db.vars.MinimapButtonButtonOptions) or rawget(_G, "MinimapButtonButtonOptions")
		if type(opts) == "table" then
			if pt then
				opts.position = { pt.p, pt.rel or "UIParent", pt.rp or pt.p, pt.x or 0, pt.y or 0 }
			end
			if type(opts.scale) == "number" and mbb.SetScale then
				mbb:SetScale(opts.scale / 10)
			end
		end
	end
	if SexyMapNS and db.minimap and Minimap then
		if SexyMapNS.core and SexyMapNS.core.db then
			SexyMapNS.core.db.point = db.minimap.p
			SexyMapNS.core.db.relpoint = db.minimap.rp
			SexyMapNS.core.db.x = db.minimap.x
			SexyMapNS.core.db.y = db.minimap.y
		end
		applyPoint(Minimap, db.minimap)
	end
	local rxpF = (getRXP() and getRXP().RXPFrame) or _G.RXPFrame
	if rxpF and db.rxpFrame then
		applyPoint(rxpF, db.rxpFrame)
	end
end

local function startLoginRestore()
	if loginRestoreStarted then
		return
	end
	loginRestoreStarted = true
	harvestAllAddOns()
	harvestScanGlobals()
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" then
		harvestMetadata(arg1)
		if arg1 == "Platynator" then
			displayAddonsSettled = true
		end
		if arg1 == ADDON_NAME then
			local n = 0
			local acc = ensureProfileStore()
			if type(acc.profiles) == "table" then
				for _ in pairs(acc.profiles) do
					n = n + 1
				end
			end
			chat("4.1 loaded. " .. n .. " layout profile(s). /squid")
		end
		return
	end
	if event == "PLAYER_LOGIN" then
		displayAddonsSettled = true
		startLoginRestore()
	end
end)

local debugFrame

local function formatSaveTime(ts)
	if type(ts) ~= "number" or ts <= 0 then
		return "(never)"
	end
	if date then
		return date("%Y-%m-%d %H:%M:%S", ts)
	end
	return tostring(ts)
end

local function liveValueForCompare(key)
	local live = _G[key]
	if isAceAddonObject(live) then
		live = live.sv
	end
	return live
end

local function compareSnapToLive(key)
	local vars = ForeverLayoutFixDB.vars
	local snap = type(vars) == "table" and vars[key] or nil
	local live = liveValueForCompare(key)
	local hasSnap = snap ~= nil and (type(snap) ~= "table" or next(snap) ~= nil)
	local hasLive = live ~= nil and (type(live) ~= "table" or next(live) ~= nil)
	if not hasSnap and not hasLive then
		return "absent", 0, 0
	end
	if hasSnap and not hasLive then
		return "SNAP_ONLY", substance(snap), 0
	end
	if not hasSnap and hasLive then
		return "LIVE_ONLY", 0, substance(live)
	end
	local ss, ls = substance(snap, 8000), substance(live, 8000)
	if ss == 0 and ls == 0 then
		return "empty", 0, 0
	end
	local lo, hi = math.min(ss, ls), math.max(ss, ls)
	if hi <= 2 or (lo / math.max(1, hi)) >= 0.7 then
		return "MATCH", ss, ls
	end
	if ls < ss * 0.5 then
		return "LIVE_THINNER", ss, ls
	end
	if ls > ss * 1.5 then
		return "LIVE_RICHER", ss, ls
	end
	return "DRIFT", ss, ls
end

local function buildDebugReport()
	local lines = {}
	local function add(s)
		lines[#lines + 1] = tostring(s)
	end

	local name, realm = UnitName("player"), GetRealmName()
	local first = name and name:match("^(%S+)") or "?"
	local guid = UnitGUID and UnitGUID("player") or "?"
	local ver = getAddOnMetadata(ADDON_NAME, "Version") or "?"
	local build, _, _, tocversion = GetBuildInfo()
	local db = ForeverLayoutFixDB
	local acc = ForeverLayoutFixAccountDB

	add("FLF_REPORT_V1")
	add("=== Squid support dump ===")
	add("Paste this whole block to the addon author.")
	add(string.rep("=", 52))
	add("version: " .. tostring(ver))
	add("addon: " .. tostring(ADDON_NAME))
	add("client: " .. tostring(build) .. "  toc=" .. tostring(tocversion))
	add("now: " .. formatSaveTime(time and time() or 0))
	add("")
	add("--- character ---")
	add("player: " .. tostring(name))
	add("firstName: " .. tostring(first))
	add("realm: " .. tostring(realm))
	add("guid: " .. tostring(guid))
	local keys = foreverNameKeys()
	add("nameKeys:")
	if #keys == 0 then
		add("  (none)")
	else
		for i = 1, #keys do
			add("  " .. keys[i])
		end
	end
	add("")

	add("--- last /squid save ---")
	add("at: " .. formatSaveTime(db.lastSaveAt))
	add("count: " .. tostring(db.lastSaveCount or 0))
	add("player: " .. tostring(db.lastSavePlayer))
	add("realm: " .. tostring(db.lastSaveRealm))
	add("guid: " .. tostring(db.lastSaveGuid))
	add("forced: " .. tostring(db.lastSaveForce))
	if db.lastSavePlayer and name and db.lastSavePlayer ~= name then
		add("WARN: last save was a different character (" .. tostring(db.lastSavePlayer) .. ")")
	end
	if db.lastSaveRealm and realm and db.lastSaveRealm ~= realm then
		add("WARN: last save was a different realm (" .. tostring(db.lastSaveRealm) .. ")")
	end
	add("")

	add("--- character snapshot (ForeverLayoutFixDB) ---")
	local n = varsCount()
	add("tables: " .. n)
	add("rxpStep: " .. tostring(db.rxpStep) .. "  rxpName: " .. tostring(db.rxpName))
	add("sexyMapShape: " .. tostring(db.sexyMapShape))
	add("has minimap point: " .. tostring(type(db.minimap) == "table"))
	add("has mbb point: " .. tostring(type(db.mbb) == "table"))
	local em = db.editMode
	add("editMode: " .. tostring(type(em) == "table" and (em.activeName or em.activeLayout) or "no"))
	local macros = db.macros
	local accM = (type(macros) == "table" and type(macros.account) == "table" and #macros.account) or 0
	local charM = (type(macros) == "table" and type(macros.character) == "table" and #macros.character) or 0
	add("macros: account=" .. accM .. " character=" .. charM)
	local barN = 0
	if type(db.actionBars) == "table" then
		for _ in pairs(db.actionBars) do
			barN = barN + 1
		end
	end
	add("actionBar slots: " .. barN)
	local cvarN = 0
	if type(db.cvars) == "table" then
		for _ in pairs(db.cvars) do
			cvarN = cvarN + 1
		end
	end
	add("cvars: " .. cvarN .. "  bindings: " .. tostring(type(db.bindings) == "table" and #db.bindings or 0))
	add("")

	local flags = {
		{ "SexyMap2DB", "SexyMap" },
		{ "RXPSettings", "RXP" },
		{ "RXPCData", "RXPCData" },
		{ "LeaPlusDB", "LeatrixPlus" },
		{ "LeaMapsDB", "LeatrixMaps" },
		{ "Bartender4DB", "Bartender4" },
		{ "PLATYNATOR_CONFIG", "Platynator" },
		{ "BAGANATOR_CONFIG", "Baganator" },
		{ "SYNDICATOR_CONFIG", "Syndicator" },
		{ "MSUF_DB", "MSUF_DB" },
		{ "MSUF_GlobalDB", "MSUF_Global" },
		{ "EllesmereUIDB", "Ellesmere" },
		{ "WIM3_Data", "WIM/GODMODE" },
		{ "PlaterDB", "Plater" },
		{ "QuestieForeverDB", "Questie" },
		{ "AtlasLootClassicDB", "AtlasLoot" },
	}
	add("--- snapshot vs live match ---")
	add("(MATCH=ok, LIVE_THINNER=live looks reset, SNAP_ONLY=saved but not in memory)")
	local matchN, driftN, thinN, liveOnlyN, snapOnlyN = 0, 0, 0, 0, 0
	for i = 1, #flags do
		local key, label = flags[i][1], flags[i][2]
		local status, ss, ls = compareSnapToLive(key)
		if status == "MATCH" then
			matchN = matchN + 1
		elseif status == "LIVE_THINNER" then
			thinN = thinN + 1
		elseif status == "LIVE_ONLY" then
			liveOnlyN = liveOnlyN + 1
		elseif status == "SNAP_ONLY" then
			snapOnlyN = snapOnlyN + 1
		elseif status == "DRIFT" or status == "LIVE_RICHER" then
			driftN = driftN + 1
		end
		if status ~= "absent" then
			add(string.format("  %-14s  %-12s  snap=%-4s live=%-4s  key=%s", label, status, tostring(ss), tostring(ls), key))
		end
	end
	add(string.format("summary: MATCH=%d  DRIFT=%d  LIVE_THINNER=%d  SNAP_ONLY=%d  LIVE_ONLY=%d", matchN, driftN, thinN, snapOnlyN, liveOnlyN))
	add("")

	add("--- all mirrored table names ---")
	local names = {}
	if type(db.vars) == "table" then
		for k, v in pairs(db.vars) do
			names[#names + 1] = { k = k, n = substance(v) }
		end
	end
	table.sort(names, function(a, b)
		return a.k < b.k
	end)
	if #names == 0 then
		add("  (empty)")
	else
		for i = 1, #names do
			add(string.format("  %s  (%s)", names[i].k, tostring(names[i].n)))
		end
	end
	add("")

	add("--- account backup (ForeverLayoutFixAccountDB) ---")
	if type(acc) ~= "table" then
		add("STATUS: MISSING — account SavedVariables did not load")
	else
		local packKeys = {}
		for k, v in pairs(acc) do
			if type(k) == "string" and k:sub(1, 1) ~= "_" and type(v) == "table" and type(v.vars) == "table" then
				local count = 0
				for _ in pairs(v.vars) do
					count = count + 1
				end
				packKeys[#packKeys + 1] = { k = k, n = substance(v.vars), count = count }
			end
		end
		table.sort(packKeys, function(a, b)
			return a.k < b.k
		end)
		add("STATUS: loaded")
		add("packs: " .. #packKeys)
		for i = 1, #packKeys do
			add(string.format("  %s  tables=%s substance=%s", packKeys[i].k, tostring(packKeys[i].count), tostring(packKeys[i].n)))
		end
		add("account lastSaveAt: " .. formatSaveTime(acc._lastSaveAt))
		add("account lastSaveCount: " .. tostring(acc._lastSaveCount))
		add("account lastSavePlayer: " .. tostring(acc._lastSavePlayer))
		add("account lastSaveRealm: " .. tostring(acc._lastSaveRealm))
		if acc._last then
			add("_last substance: " .. packSubstance(acc._last))
			add("_lastFullName: " .. tostring(acc._lastFullName))
			add("_lastRealm: " .. tostring(acc._lastRealm))
			add("_lastGuid: " .. tostring(acc._lastGuid))
		else
			add("_last: (none)")
		end
		add("key hits for this character:")
		local hit = false
		for i = 1, #keys do
			if type(acc[keys[i]]) == "table" then
				hit = true
				add("  HIT " .. keys[i] .. " substance=" .. packSubstance(acc[keys[i]]))
			end
		end
		if type(guid) == "string" and type(acc[guid]) == "table" then
			hit = true
			add("  HIT guid substance=" .. packSubstance(acc[guid]))
		end
		if not hit then
			add("  (none)")
		end
	end
	add("")

	add("--- runtime ---")
	add("LeaPlusLC captured: " .. tostring(getLeaPlusLC() ~= nil))
	add("LeaPlusLC global: " .. tostring(type(_G.LeaPlusLC) == "table"))
	add("LeaMapsLC global: " .. tostring(type(_G.LeaMapsLC) == "table"))
	add("SexyMapNS: " .. tostring(SexyMapNS ~= nil))
	add("MSUF_InitProfiles: " .. tostring(type(MSUF_InitProfiles) == "function"))
	add("EllesmereUI: " .. tostring(_G.EllesmereUI ~= nil))
	add("loginRestoreStarted: " .. tostring(loginRestoreStarted))
	add("verbose: " .. (debugOn and "ON" or "OFF"))
	add("")
	add("=== end FLF_REPORT_V1 ===")
	return table.concat(lines, "\n")
end

-- EllesmereUI-inspired palette for the support dump window.
local FLF_UI = {
	bg = { 0.067, 0.067, 0.067, 0.97 }, -- #111
	panel = { 0.10, 0.10, 0.10, 1 },
	header = { 0.09, 0.09, 0.09, 1 },
	teal = { 0.00, 0.90, 0.78, 1 }, -- #00E6C7
	tealDim = { 0.00, 0.55, 0.48, 0.85 },
	orange = { 0.90, 0.29, 0.10, 1 }, -- #E64A19
	text = { 0.92, 0.92, 0.92, 1 },
	muted = { 0.55, 0.58, 0.60, 1 },
	btn = { 0.14, 0.14, 0.14, 1 },
	btnHover = { 0.18, 0.18, 0.18, 1 },
}

local function flfSolidBackdrop()
	return {
		bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8",
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	}
end

local function flfApplyBackdrop(frame, color, border)
	if not frame.SetBackdrop then
		return
	end
	frame:SetBackdrop(flfSolidBackdrop())
	if color then
		frame:SetBackdropColor(color[1], color[2], color[3], color[4] or 1)
	end
	if border then
		frame:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
	else
		frame:SetBackdropBorderColor(0, 0, 0, 0)
	end
end

local function flfMakeButton(parent, label, width, primary)
	local btn = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	btn:SetSize(width or 100, 28)
	flfApplyBackdrop(
		btn,
		primary and { FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 0.95 } or FLF_UI.btn,
		primary and { FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1 } or FLF_UI.tealDim
	)
	local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	fs:SetPoint("CENTER")
	if primary then
		fs:SetTextColor(0.05, 0.07, 0.07, 1)
	else
		fs:SetTextColor(FLF_UI.text[1], FLF_UI.text[2], FLF_UI.text[3], 1)
	end
	fs:SetText(label)
	btn.label = fs
	btn:SetScript("OnEnter", function(self)
		if primary then
			flfApplyBackdrop(self, { 0.15, 1.0, 0.88, 1 }, FLF_UI.teal)
		else
			flfApplyBackdrop(self, FLF_UI.btnHover, FLF_UI.teal)
		end
	end)
	btn:SetScript("OnLeave", function(self)
		if primary then
			flfApplyBackdrop(self, { FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 0.95 }, FLF_UI.teal)
		else
			flfApplyBackdrop(self, FLF_UI.btn, FLF_UI.tealDim)
		end
	end)
	btn.SetLabel = function(self, text)
		self.label:SetText(text)
	end
	return btn
end

local function ensureDebugFrame()
	if debugFrame then
		-- Old 3.1 frame called protected CopyToClipboard; rebuild after upgrade.
		if debugFrame._flfUiVer ~= 27 then
			debugFrame:Hide()
			debugFrame = nil
		else
			return debugFrame
		end
	end

	local f = CreateFrame("Frame", "ForeverLayoutFixDebugFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	f:SetSize(680, 560)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	flfApplyBackdrop(f, FLF_UI.bg, { FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 0.55 })
	if not f.SetBackdrop then
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(FLF_UI.bg[1], FLF_UI.bg[2], FLF_UI.bg[3], FLF_UI.bg[4])
	end
	tinsert(UISpecialFrames, "ForeverLayoutFixDebugFrame")

	local header = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(64)
	flfApplyBackdrop(header, FLF_UI.header, nil)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function()
		f:StartMoving()
	end)
	header:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
	end)

	local accent = header:CreateTexture(nil, "ARTWORK")
	accent:SetPoint("BOTTOMLEFT", 0, 0)
	accent:SetPoint("BOTTOMRIGHT", 0, 0)
	accent:SetHeight(2)
	accent:SetColorTexture(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)

	local brand = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	brand:SetPoint("TOPLEFT", 18, -14)
	brand:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
	brand:SetText("Squid")

	local sub = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", brand, "BOTTOMLEFT", 0, -4)
	sub:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	sub:SetText("Support dump  ·  Select All, then Ctrl+C to copy")

	local ver = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ver:SetPoint("TOPRIGHT", -40, -18)
	ver:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	local metaVer = "4.1"
	pcall(function()
		if C_AddOns and C_AddOns.GetAddOnMetadata then
			metaVer = C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version") or metaVer
		elseif GetAddOnMetadata then
			metaVer = GetAddOnMetadata(ADDON_NAME, "Version") or metaVer
		end
	end)
	ver:SetText("v" .. tostring(metaVer))

	local close = CreateFrame("Button", nil, header)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -10, -12)
	local closeFs = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	closeFs:SetPoint("CENTER", 0, 1)
	closeFs:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	closeFs:SetText("×")
	close:SetScript("OnEnter", function()
		closeFs:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
	end)
	close:SetScript("OnLeave", function()
		closeFs:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	end)
	close:SetScript("OnClick", function()
		f:Hide()
	end)

	local body = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	body:SetPoint("TOPLEFT", 14, -76)
	body:SetPoint("BOTTOMRIGHT", -14, 58)
	flfApplyBackdrop(body, FLF_UI.panel, { 0.16, 0.16, 0.16, 1 })

	local scroll = CreateFrame("ScrollFrame", "ForeverLayoutFixDebugScroll", body, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -10)
	scroll:SetPoint("BOTTOMRIGHT", -28, 10)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetFontObject(GameFontHighlightSmall)
	pcall(function()
		edit:SetFont("Fonts\\ARIALN.TTF", 12, "")
	end)
	edit:SetTextColor(FLF_UI.text[1], FLF_UI.text[2], FLF_UI.text[3], 1)
	edit:SetWidth(600)
	edit:SetAutoFocus(false)
	edit:EnableMouse(true)
	edit:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		f:Hide()
	end)
	scroll:SetScrollChild(edit)
	f.edit = edit
	f.scroll = scroll

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", 18, 22)
	status:SetWidth(300)
	status:SetJustifyH("LEFT")
	status:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	status:SetText("")
	f.status = status

	local copyBtn = flfMakeButton(f, "Select All", 110, true)
	copyBtn:SetPoint("BOTTOMRIGHT", -18, 16)

	local saveBtn = flfMakeButton(f, "Save", 72, false)
	saveBtn:SetPoint("RIGHT", copyBtn, "LEFT", -8, 0)

	local refresh = flfMakeButton(f, "Refresh", 80, false)
	refresh:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)

	local function fillReport()
		local text = buildDebugReport()
		f.reportText = text
		edit:SetText(text)
		local lineCount = 1
		for _ in string.gmatch(text, "\n") do
			lineCount = lineCount + 1
		end
		edit:SetHeight(math.max(420, lineCount * 14 + 20))
		edit:SetCursorPosition(0)
		scroll:SetVerticalScroll(0)
	end

	local function armSelection()
		f._copyArmed = true
		edit:SetFocus()
		edit:HighlightText()
		status:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
		status:SetText("Selected — press Ctrl+C, then paste to the author.")
		copyBtn:SetLabel("Ctrl+C now")
		if C_Timer and C_Timer.After then
			C_Timer.After(4, function()
				if copyBtn:IsShown() then
					copyBtn:SetLabel("Select All")
				end
			end)
		end
	end

	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput and f.reportText and self:GetText() ~= f.reportText then
			local pos = self:GetCursorPosition()
			self:SetText(f.reportText)
			self:SetCursorPosition(math.min(pos, #f.reportText))
		end
	end)
	edit:SetScript("OnEditFocusGained", function(self)
		if f._copyArmed then
			self:HighlightText()
		end
	end)
	edit:SetScript("OnMouseUp", function(self)
		if f._copyArmed then
			self:HighlightText()
		end
	end)

	local function doCopy()
		fillReport()
		armSelection()
	end

	refresh:SetScript("OnClick", function()
		f._copyArmed = false
		fillReport()
		status:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
		status:SetText("Report refreshed.")
	end)
	saveBtn:SetScript("OnClick", function()
		f._copyArmed = false
		saveAll(true)
		fillReport()
		status:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
		status:SetText("Snapshot saved — report updated.")
	end)
	copyBtn:SetScript("OnClick", doCopy)

	f:SetScript("OnShow", function()
		f._copyArmed = false
		fillReport()
		status:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
		status:SetText("Click Select All, then Ctrl+C to copy.")
	end)
	f:SetScript("OnHide", function()
		f._copyArmed = false
	end)

	debugFrame = f
	f._flfUiVer = 27
	return f
end

local function showDebugWindow()
	local f = ensureDebugFrame()
	f:Show()
	f:Raise()
end

local exportFrame
local EXPORT_FROM_REL = "WTF\\Account\\<account>\\SavedVariables\\Squid.lua"
local EXPORT_TO_REL = "Interface\\AddOns\\Squid\\offline.lua"

local function ensureExportFrame()
	if exportFrame then
		return exportFrame
	end

	local f = CreateFrame("Frame", "ForeverLayoutFixExportFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	f:SetSize(580, 420)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	flfApplyBackdrop(f, FLF_UI.bg, { FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 0.55 })
	tinsert(UISpecialFrames, "ForeverLayoutFixExportFrame")

	local header = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(64)
	flfApplyBackdrop(header, FLF_UI.header, nil)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function()
		f:StartMoving()
	end)
	header:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
	end)

	local accent = header:CreateTexture(nil, "ARTWORK")
	accent:SetPoint("BOTTOMLEFT", 0, 0)
	accent:SetPoint("BOTTOMRIGHT", 0, 0)
	accent:SetHeight(2)
	accent:SetColorTexture(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)

	local brand = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	brand:SetPoint("TOPLEFT", 18, -14)
	brand:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
	brand:SetText("Export fallback")

	local sub = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", brand, "BOTTOMLEFT", 0, -4)
	sub:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	sub:SetText("WoW cannot write the AddOns folder — copy the WTF file yourself after close")

	local close = CreateFrame("Button", nil, header)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -10, -12)
	local closeFs = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	closeFs:SetPoint("CENTER", 0, 1)
	closeFs:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	closeFs:SetText("×")
	close:SetScript("OnEnter", function()
		closeFs:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
	end)
	close:SetScript("OnLeave", function()
		closeFs:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	end)
	close:SetScript("OnClick", function()
		f:Hide()
	end)

	local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	body:SetPoint("TOPLEFT", 22, -84)
	body:SetPoint("TOPRIGHT", -22, -84)
	body:SetJustifyH("LEFT")
	body:SetJustifyV("TOP")
	body:SetSpacing(3)
	body:SetHeight(88)
	body:SetTextColor(FLF_UI.text[1], FLF_UI.text[2], FLF_UI.text[3], 1)
	body:SetText(
		"1. This snapshot is queued for WTF SavedVariables.\n"
			.. "2. Fully close WoW so the game can write that file.\n"
			.. "3. Copy the WTF file below and replace the addon file below.\n"
			.. "   (Copy, paste, rename to FLF_OfflineFallback.lua if asked.)"
	)
	f.body = body

	local function makePathRow(labelText, defaultText, anchor)
		local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -12)
		label:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
		label:SetText(labelText)
		local box = CreateFrame("EditBox", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
		box:SetHeight(28)
		box:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
		box:SetPoint("RIGHT", f, "RIGHT", -22, 0)
		box:SetAutoFocus(false)
		box:SetFontObject(GameFontHighlightSmall)
		box:SetTextInsets(8, 8, 0, 0)
		box:SetText(defaultText)
		box:SetCursorPosition(0)
		box:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
		end)
		box:SetScript("OnTextChanged", function(self, userInput)
			if userInput then
				self:SetText(defaultText)
				self:SetCursorPosition(0)
			end
		end)
		if box.SetBackdrop then
			flfApplyBackdrop(box, FLF_UI.panel, { 0.16, 0.16, 0.16, 1 })
		end
		return box
	end

	local fromBox = makePathRow("Copy this file (after closing WoW):", EXPORT_FROM_REL, body)
	local toBox = makePathRow("Replace this file in the addon folder:", EXPORT_TO_REL, fromBox)
	f.fromBox = fromBox
	f.toBox = toBox

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", 18, 22)
	status:SetWidth(280)
	status:SetJustifyH("LEFT")
	status:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	f.status = status

	local copyBtn = flfMakeButton(f, "Copy WTF path", 130, true)
	copyBtn:SetPoint("BOTTOMRIGHT", -18, 16)
	copyBtn:SetScript("OnClick", function()
		fromBox:SetFocus()
		fromBox:HighlightText()
		local copied = false
		if CopyToClipboard then
			copied = pcall(CopyToClipboard, EXPORT_FROM_REL)
		end
		if copied then
			status:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
			status:SetText("WTF path copied — close WoW, then copy that file.")
		else
			status:SetTextColor(FLF_UI.orange[1], FLF_UI.orange[2], FLF_UI.orange[3], 1)
			status:SetText("Selected — Ctrl+C, close WoW, then copy the file.")
		end
	end)

	local saveBtn = flfMakeButton(f, "Save now", 90, false)
	saveBtn:SetPoint("RIGHT", copyBtn, "LEFT", -8, 0)
	saveBtn:SetScript("OnClick", function()
		local n = saveAll(true)
		status:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
		status:SetText("Saved " .. tostring(n) .. " tables. Close WoW, then copy the WTF file.")
	end)

	f:SetScript("OnShow", function()
		fromBox:SetText(EXPORT_FROM_REL)
		fromBox:SetCursorPosition(0)
		toBox:SetText(EXPORT_TO_REL)
		toBox:SetCursorPosition(0)
		status:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
		status:SetText("Close the game first — the dump is written on logout.")
	end)

	exportFrame = f
	return f
end

local function showExportWindow()
	saveAll(true)
	local f = ensureExportFrame()
	f:Show()
	f:Raise()
	if f.status then
		f.status:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
		f.status:SetText("Snapshot queued. Close WoW, then copy the WTF file yourself.")
	end
end

local profileFrame
local selectedProfileName

local function diskBridgeOn()
	return rawget(_G, "FLF_DISK_READY") == true
end

local function ensureProfileFrame()
	if profileFrame then
		return profileFrame
	end

	local f = CreateFrame("Frame", "ForeverLayoutFixProfileFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
	f:SetSize(560, 460)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetClampedToScreen(true)
	flfApplyBackdrop(f, FLF_UI.bg, { FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 0.55 })
	tinsert(UISpecialFrames, "ForeverLayoutFixProfileFrame")

	local header = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(64)
	flfApplyBackdrop(header, FLF_UI.header, nil)
	header:EnableMouse(true)
	header:RegisterForDrag("LeftButton")
	header:SetScript("OnDragStart", function()
		f:StartMoving()
	end)
	header:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
	end)

	local accent = header:CreateTexture(nil, "ARTWORK")
	accent:SetPoint("BOTTOMLEFT", 0, 0)
	accent:SetPoint("BOTTOMRIGHT", 0, 0)
	accent:SetHeight(2)
	accent:SetColorTexture(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)

	local brand = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	brand:SetPoint("TOPLEFT", 18, -14)
	brand:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
	brand:SetText("Squid")

	local sub = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", brand, "BOTTOMLEFT", 0, -4)
	sub:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	f.sub = sub

	local close = CreateFrame("Button", nil, header)
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -10, -12)
	local closeFs = close:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	closeFs:SetPoint("CENTER", 0, 1)
	closeFs:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	closeFs:SetText("×")
	close:SetScript("OnEnter", function()
		closeFs:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
	end)
	close:SetScript("OnLeave", function()
		closeFs:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	end)
	close:SetScript("OnClick", function()
		f:Hide()
	end)

	local nameBox = CreateFrame("EditBox", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	nameBox:SetHeight(28)
	nameBox:SetPoint("TOPLEFT", 18, -80)
	nameBox:SetPoint("RIGHT", f, "RIGHT", -18, 0)
	nameBox:SetAutoFocus(false)
	nameBox:SetFontObject(GameFontHighlight)
	nameBox:SetTextInsets(8, 8, 0, 0)
	nameBox:SetMaxLetters(40)
	nameBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	nameBox:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
	end)
	if nameBox.SetBackdrop then
		flfApplyBackdrop(nameBox, FLF_UI.panel, { 0.16, 0.16, 0.16, 1 })
	end
	f.nameBox = nameBox

	local list = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
	list:SetPoint("TOPLEFT", 18, -118)
	list:SetPoint("BOTTOMRIGHT", -18, 96)
	flfApplyBackdrop(list, FLF_UI.panel, { 0.16, 0.16, 0.16, 1 })
	f.list = list
	f.rows = {}

	local emptyHint = list:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	emptyHint:SetPoint("TOPLEFT", 12, -12)
	emptyHint:SetPoint("RIGHT", -12, 0)
	emptyHint:SetJustifyH("LEFT")
	emptyHint:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	emptyHint:SetText("No profiles yet. Set up your UI, type a name above, then Save settings.")
	f.emptyHint = emptyHint

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	status:SetPoint("BOTTOMLEFT", 18, 58)
	status:SetPoint("RIGHT", f, "RIGHT", -18, 0)
	status:SetJustifyH("LEFT")
	status:SetTextColor(FLF_UI.muted[1], FLF_UI.muted[2], FLF_UI.muted[3], 1)
	f.status = status

	local function setStatus(text, ok)
		if ok then
			status:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
		else
			status:SetTextColor(FLF_UI.orange[1], FLF_UI.orange[2], FLF_UI.orange[3], 1)
		end
		status:SetText(text or "")
	end
	f.setStatus = setStatus

	local function refreshList()
		local acc = ensureProfileStore()
		local names = listProfileNames()
		if not selectedProfileName or not acc.profiles[selectedProfileName] then
			selectedProfileName = acc.activeProfile or names[1]
		end
		if selectedProfileName then
			nameBox:SetText(selectedProfileName)
		end
		for i = 1, math.max(#f.rows, #names, 1) do
			local row = f.rows[i]
			if not row then
				row = CreateFrame("Button", nil, list, BackdropTemplateMixin and "BackdropTemplate" or nil)
				row:SetHeight(26)
				row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 28)
				row:SetPoint("RIGHT", -6, 0)
				row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				row.label:SetPoint("LEFT", 8, 0)
				row.label:SetPoint("RIGHT", -8, 0)
				row.label:SetJustifyH("LEFT")
				row:SetScript("OnClick", function(self)
					if self.profileName then
						selectedProfileName = self.profileName
						nameBox:SetText(self.profileName)
						refreshList()
					end
				end)
				f.rows[i] = row
			end
			local name = names[i]
			if name then
				row.profileName = name
				row:Show()
				local rec = acc.profiles[name]
				local mark = (ForeverLayoutFixDB.lastProfile == name) and "  (this character)" or ""
				row.label:SetText(name .. mark)
				if name == selectedProfileName then
					row.label:SetTextColor(FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3], 1)
					flfApplyBackdrop(row, FLF_UI.btnHover, FLF_UI.tealDim)
				else
					row.label:SetTextColor(FLF_UI.text[1], FLF_UI.text[2], FLF_UI.text[3], 1)
					flfApplyBackdrop(row, FLF_UI.btn, { 0.16, 0.16, 0.16, 1 })
				end
				if rec and rec.savedPlayer then
					row:SetScript("OnEnter", function()
						GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
						GameTooltip:AddLine(name, FLF_UI.teal[1], FLF_UI.teal[2], FLF_UI.teal[3])
						GameTooltip:AddLine("Saved by " .. tostring(rec.savedPlayer) .. " / " .. tostring(rec.savedRealm or ""), 0.8, 0.8, 0.8)
						if rec.savedAt then
							GameTooltip:AddLine(formatSaveTime(rec.savedAt), 0.6, 0.6, 0.6)
						end
						GameTooltip:Show()
					end)
					row:SetScript("OnLeave", function()
						GameTooltip:Hide()
					end)
				end
			else
				row.profileName = nil
				row:Hide()
			end
		end
		if f.emptyHint then
			if #names == 0 then
				f.emptyHint:Show()
			else
				f.emptyHint:Hide()
			end
		end
		sub:SetText("Save a layout here, then Enable it on this character.")
	end
	f.refreshList = refreshList

	local function currentName()
		return sanitizeProfileName(nameBox:GetText()) or selectedProfileName
	end

	local saveBtn = flfMakeButton(f, "Save settings", 120, true)
	saveBtn:SetPoint("BOTTOMRIGHT", -18, 16)
	saveBtn:SetScript("OnClick", function()
		local ok, err = saveToProfile(currentName() or "Default")
		if ok then
			selectedProfileName = err
			setStatus("Saved '" .. err .. "'. Enable it on another character (or this one) when you want that layout.", true)
			refreshList()
		else
			setStatus(err or "Save failed.", false)
		end
	end)

	local useBtn = flfMakeButton(f, "Enable", 80, false)
	useBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
	useBtn:SetScript("OnClick", function()
		local ok, err = setActiveProfile(currentName(), true)
		if ok then
			snapshotPrefer.BAGANATOR_CONFIG = true
			snapshotPrefer.BAGANATOR_CURRENT_PROFILE = true
			snapshotPrefer.SYNDICATOR_CONFIG = true
			snapshotPrefer.SexyMap2DB = true
			snapshotPrefer.XLootADB = true
			local applied = applyActiveProfilePack()
			if applied then
				local vars = ForeverLayoutFixDB.vars
				if type(vars) == "table" then
					pcall(injectOne, "BAGANATOR_CONFIG", vars.BAGANATOR_CONFIG, true)
					pcall(injectOne, "BAGANATOR_CURRENT_PROFILE", vars.BAGANATOR_CURRENT_PROFILE, true)
					pcall(injectOne, "SYNDICATOR_CONFIG", vars.SYNDICATOR_CONFIG, true)
					pcall(injectOne, "SexyMap2DB", vars.SexyMap2DB, true)
					pcall(injectOne, "XLootADB", vars.XLootADB, true)
				end
				injectVars({ late = true })
				restoreLive()
				restoreProfileAddons(true)
				applyFrames()
				pcall(applyLeatrixSnapshot, { markPending = true })
				local ui = restoreBlizzardUI({ bars = true })
				local extra = ""
				if ui.barErr == "in combat" then
					extra = " Action bars skipped (leave combat, click Enable again)."
				elseif (ui.bars or 0) > 0 then
					extra = " Restored " .. ui.bars .. " action-bar slots."
				end
				if (ui.macros or 0) > 0 then
					extra = extra .. " Macros " .. ui.macros .. "."
				end
				if ui.edit then
					extra = extra .. " Edit Mode applied."
				end
				setStatus("Enabled '" .. err .. "'." .. extra .. " Type /reload to apply Platynator, RXP size, and other addon settings.", true)
				chat("Enabled '" .. tostring(err) .. "'." .. extra .. " Type /reload to apply it.")
				refreshList()
			else
				setStatus("Enabled '" .. err .. "' but the pack was empty. Save settings on your main first.", false)
				refreshList()
			end
		else
			setStatus(err or "Enable failed.", false)
		end
	end)

	local offBtn = flfMakeButton(f, "Disable", 80, false)
	offBtn:SetPoint("RIGHT", useBtn, "LEFT", -8, 0)
	offBtn:SetScript("OnClick", function()
		local acc = ensureProfileStore()
		acc.profileEnabled = false
		setStatus("Profiles disabled. Characters use their own snapshots again.", true)
		refreshList()
	end)

	local newBtn = flfMakeButton(f, "New", 60, false)
	newBtn:SetPoint("BOTTOMLEFT", 18, 16)
	newBtn:SetScript("OnClick", function()
		local name = currentName() or "Default"
		if ensureProfileStore().profiles[name] then
			local i = 2
			while ensureProfileStore().profiles[name .. " " .. i] do
				i = i + 1
			end
			name = name .. " " .. i
		end
		nameBox:SetText(name)
		selectedProfileName = name
		local ok, err = saveToProfile(name)
		if ok then
			setStatus("Created '" .. err .. "'.", true)
			refreshList()
		else
			setStatus(err or "Create failed.", false)
		end
	end)

	local renameBtn = flfMakeButton(f, "Rename", 80, false)
	renameBtn:SetPoint("LEFT", newBtn, "RIGHT", 8, 0)
	renameBtn:SetScript("OnClick", function()
		local ok, err = renameProfile(selectedProfileName, nameBox:GetText())
		if ok then
			selectedProfileName = err
			setStatus("Renamed to '" .. err .. "'.", true)
			refreshList()
		else
			setStatus(err or "Rename failed.", false)
		end
	end)

	local delBtn = flfMakeButton(f, "Delete", 70, false)
	delBtn:SetPoint("LEFT", renameBtn, "RIGHT", 8, 0)
	delBtn:SetScript("OnClick", function()
		local name = selectedProfileName
		local ok, err = deleteProfile(name)
		if ok then
			selectedProfileName = nil
			nameBox:SetText("")
			setStatus("Deleted '" .. tostring(name) .. "'.", true)
			refreshList()
		else
			setStatus(err or "Delete failed.", false)
		end
	end)

	f:SetScript("OnShow", function()
		sub:SetText("Save a layout here, then Enable it on this character.")
		setStatus("Profiles are account-wide. Enable copies addon options, macros, binds, and bars onto this character.", true)
		refreshList()
		C_Timer.After(0, refreshList)
	end)

	profileFrame = f
	return f
end

local function showProfileWindow()
	local f = ensureProfileFrame()
	f:Show()
	f:Raise()
	if f.refreshList then
		f.refreshList()
		C_Timer.After(0, f.refreshList)
	end
end

SLASH_SQUID1 = "/squid"
SLASH_SQUID2 = "/flf"
SLASH_SQUID3 = "/ff"
SlashCmdList.SQUID = function(msg)
	local raw = strtrim(tostring(msg or ""))
	msg = string.lower(raw)
	if msg == "" or msg == "profiles" or msg == "profile" then
		showProfileWindow()
		return
	end
	if msg == "verbose" then
		debugOn = not debugOn
		ForeverLayoutFixDB.debug = debugOn
		chat("verbose logging " .. (debugOn and "ON" or "OFF") .. " (inject/snapshot chatter)")
		return
	end
	if msg == "debug" then
		showDebugWindow()
		return
	end
	if msg == "save" then
		local acc = ensureProfileStore()
		local name = sanitizeProfileName(ForeverLayoutFixDB.lastProfile) or sanitizeProfileName(acc.activeProfile)
		if not name then
			showProfileWindow()
			chat("Type a profile name in /squid, then Save settings.")
			return
		end
		local ok, err = saveToProfile(name)
		if ok then
			chat("saved layout '" .. err .. "'. Enable it on another character when you want it.")
		else
			chat(err or "Save failed.")
		end
		return
	end
	if msg == "help" then
		chat("/squid            — layout profiles")
		chat("/squid profiles   — save / enable / switch layouts")
		chat("/squid save       — overwrite the last layout used on this character")
		chat("/squid list       — addon tables in the current snapshot")
		chat("/squid debug      — support dump")
		chat("/flf or /ff       — same as /squid")
		return
	end
	local vars = ForeverLayoutFixDB.vars
	local n = 0
	local names = {}
	if type(vars) == "table" then
		for k in pairs(vars) do
			n = n + 1
			names[#names + 1] = k
		end
		table.sort(names)
	end
	if msg == "list" or n <= 50 then
		chat("snapshot tables=" .. n .. (n > 0 and (": " .. table.concat(names, ", ")) or " (none — Save settings in /squid)"))
	else
		chat("snapshot tables=" .. n .. " (type /squid list for names)")
	end
end
