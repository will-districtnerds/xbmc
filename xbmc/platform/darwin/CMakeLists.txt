set(SOURCES AutoPool.mm
            DarwinUtils.mm
            DarwinNSUserDefaults.mm
            DictionaryUtils.mm
            OSXGNUReplacements.c
            PlatformDarwin.cpp
            NSData+GZIP.m)

set(HEADERS AutoPool.h
            DarwinNSUserDefaults.h
            DarwinUtils.h
            DictionaryUtils.h
            NSLogDebugHelpers.h
            OSXGNUReplacements.h
            PlatformDarwin.h
            NSData+GZIP.h)

core_add_library(platform_darwin)
