-- Native SavedVariables already loaded. Do not execute the WTF file
-- again through the Disk junction (that errors and disables this addon).
FLF_DISK_READY = type(ForeverLayoutFixProfilesDB) == "table"
FLF_DiskProfiles = ForeverLayoutFixProfilesDB
