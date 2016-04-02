set(SOURCES CocoaInterface.mm
            cocoa_monitor.mm
            HotKeyController.m
            OSXTextInputResponder.mm
            OSXGLView.mm
            OSXGLWindow.mm
            smc.c
            XBMCHelper.cpp)

set(HEADERS CocoaInterface.h
            HotKeyController.h
            OSXTextInputResponder.h
            OSXGLView.h
            OSXGLWindow.h
            smc.h
            XBMCHelper.h)

core_add_library(platform_osx)
