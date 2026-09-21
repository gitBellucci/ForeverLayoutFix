-- Merge published profiles into native SavedVariables. Native leftover
-- profiles (e.g. an alt creating "x") must not hide the layouts from
-- FLF_Setup.cmd. Published wins when it is newer or the local copy has no pack.

local function FLF_MergeProfileStores(dst, src)
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

local published = rawget(_G, "FLF_PublishedSnapshot")
if type(published) == "table" then
	ForeverLayoutFixProfilesDB = FLF_MergeProfileStores(ForeverLayoutFixProfilesDB, published)
end

if type(ForeverLayoutFixProfilesDB) == "table" and type(ForeverLayoutFixProfilesDB.profiles) == "table" and next(ForeverLayoutFixProfilesDB.profiles) then
	FLF_DiskProfiles = ForeverLayoutFixProfilesDB
	FLF_DISK_READY = true
else
	FLF_DISK_READY = false
end
