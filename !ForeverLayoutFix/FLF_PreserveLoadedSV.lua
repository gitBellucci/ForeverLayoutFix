-- Keep whatever SavedVariables actually loaded this launch.
-- FLF_OfflineFallback.lua may be a user-copied WTF dump and must not
-- overwrite a good in-memory load with an older file.
FLF_PreDumpAccountDB = ForeverLayoutFixAccountDB
FLF_PreDumpCharDB = ForeverLayoutFixDB
FLF_PreDumpFallback = rawget(_G, "FLF_OfflineFallback")
