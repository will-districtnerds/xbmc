/*
 *      Copyright (C) 2005-2015 Team Kodi
 *      http://kodi.tv
 *
 *  This Program is free software; you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation; either version 2, or (at your option)
 *  any later version.
 *
 *  This Program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with Kodi; see the file COPYING.  If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */

#if defined(TARGET_DARWIN_OSX)

//hack around problem with xbmc's typedef int BOOL
// and obj-c's typedef unsigned char BOOL
#define BOOL XBMC_BOOL
#include "WinSystemOSX.h"
#include "Application.h"
#include "messaging/ApplicationMessenger.h"
#include "guilib/DispResource.h"
#include "guilib/GUIWindowManager.h"
#include "settings/Settings.h"
#include "settings/DisplaySettings.h"
#include "utils/log.h"
#include "utils/StringUtils.h"
#include "platform/darwin/osx/XBMCHelper.h"
#include "utils/SystemInfo.h"
#include "platform/darwin/osx/CocoaInterface.h"
#include "platform/darwin/DictionaryUtils.h"
#include "platform/darwin/DarwinUtils.h"
#undef BOOL

#import "osx/OSX/OSXGLView.h"
#import "osx/OSX/OSXGLWindow.h"
#import "osx/OSXTextInputResponder.h"

#import <Cocoa/Cocoa.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/graphics/IOGraphicsLib.h>
#import "platform/darwin/osx/OSXTextInputResponder.h"

// turn off deprecated warning spew.
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"

#if !defined(NSWindowCollectionBehaviorFullScreenPrimary)
#define NSWindowCollectionBehaviorFullScreenPrimary (1 << 7)
#endif

//------------------------------------------------------------------------------------------
// special object-c class for handling the inhibit display NSTimer callback.
@interface windowInhibitScreenSaverClass : NSObject
- (void) updateSystemActivity: (NSTimer*)timer;
@end

@implementation windowInhibitScreenSaverClass
-(void) updateSystemActivity: (NSTimer*)timer
{
  UpdateSystemActivity(UsrActivity);
}
@end

//------------------------------------------------------------------------------------------
#define MAX_DISPLAYS 32
// if there was a devicelost callback
// but no device reset for 3 secs
// a timeout fires the reset callback
// (for ensuring that e.x. AE isn't stuck)
#define LOST_DEVICE_TIMEOUT_MS 3000
static NSWindow* blankingWindows[MAX_DISPLAYS];

//------------------------------------------------------------------------------------------
CRect CGRectToCRect(CGRect cgrect)
{
  CRect crect = CRect(
    cgrect.origin.x,
    cgrect.origin.y,
    cgrect.origin.x + cgrect.size.width,
    cgrect.origin.y + cgrect.size.height);
  return crect;
}
//---------------------------------------------------------------------------------
void SetMenuBarVisible(bool visible)
{
  // native fullscreen stuff handles this for us...
  if (!visible && CDarwinUtils::DeviceHasNativeFullscreen())
    return;

  if ([NSApplication sharedApplication] == nil)
    printf("[NSApplication sharedApplication] nil %d\n" , visible);
  
  NSApplicationPresentationOptions options = 0;
  
  if (visible)
    options = NSApplicationPresentationDefault;
  else
    options = NSApplicationPresentationHideMenuBar | NSApplicationPresentationHideDock;

  @try
  {
    if (visible)
      [OSXGLWindow performSelectorOnMainThread:@selector(SetMenuBarVisible) withObject:nil waitUntilDone:TRUE];
    else
      [OSXGLWindow performSelectorOnMainThread:@selector(SetMenuBarInvisible) withObject:nil waitUntilDone:TRUE];
//    [NSApp setPresentationOptions:options];
  }
  
  @catch(NSException *exception)
  {
    NSLog(@"Error.  Make sure you have a valid combination of options.");
  }
}
//---------------------------------------------------------------------------------
CGDirectDisplayID GetDisplayID(int screen_index)
{
  CGDirectDisplayID displayArray[MAX_DISPLAYS];
  CGDisplayCount    numDisplays;

  // Get the list of displays.
  CGGetActiveDisplayList(MAX_DISPLAYS, displayArray, &numDisplays);
  return displayArray[screen_index];
}

CGDirectDisplayID GetDisplayIDFromScreen(NSScreen *screen)
{
  NSDictionary* screenInfo = [screen deviceDescription];
  NSNumber* screenID = [screenInfo objectForKey:@"NSScreenNumber"];

  return (CGDirectDisplayID)[screenID longValue];
}

int GetDisplayIndex(CGDirectDisplayID display)
{
  CGDirectDisplayID displayArray[MAX_DISPLAYS];
  CGDisplayCount    numDisplays;

  // Get the list of displays.
  CGGetActiveDisplayList(MAX_DISPLAYS, displayArray, &numDisplays);
  while (numDisplays > 0)
  {
    if (display == displayArray[--numDisplays])
	  return numDisplays;
  }
  return -1;
}

void BlankOtherDisplays(int screen_index)
{
  int i;
  int numDisplays = [[NSScreen screens] count];

  // zero out blankingWindows for debugging
  for (i=0; i<MAX_DISPLAYS; i++)
  {
    blankingWindows[i] = 0;
  }

  // Blank.
  for (i=0; i<numDisplays; i++)
  {
    if (i != screen_index)
    {
      // Get the size.
      NSScreen* pScreen = [[NSScreen screens] objectAtIndex:i];
      NSRect    screenRect = [pScreen frame];

      // Build a blanking window.
      screenRect.origin = NSZeroPoint;
      blankingWindows[i] = [[NSWindow alloc] initWithContentRect:screenRect
        styleMask:NSBorderlessWindowMask
        backing:NSBackingStoreBuffered
        defer:NO
        screen:pScreen];

      [blankingWindows[i] setBackgroundColor:[NSColor blackColor]];
      [blankingWindows[i] setLevel:CGShieldingWindowLevel()];
      [blankingWindows[i] makeKeyAndOrderFront:nil];
    }
  }
}

void UnblankDisplays(void)
{
  int numDisplays = [[NSScreen screens] count];
  int i = 0;

  for (i=0; i<numDisplays; i++)
  {
    if (blankingWindows[i] != 0)
    {
      // Get rid of the blanking windows we created.
      [blankingWindows[i] close];
      if ([blankingWindows[i] isReleasedWhenClosed] == NO)
        [blankingWindows[i] release];
      blankingWindows[i] = 0;
    }
  }
}

CGDisplayFadeReservationToken DisplayFadeToBlack(bool fade)
{
  // Fade to black to hide resolution-switching flicker and garbage.
  CGDisplayFadeReservationToken fade_token = kCGDisplayFadeReservationInvalidToken;
  if (CGAcquireDisplayFadeReservation (5, &fade_token) == kCGErrorSuccess && fade)
    CGDisplayFade(fade_token, 0.3, kCGDisplayBlendNormal, kCGDisplayBlendSolidColor, 0.0, 0.0, 0.0, TRUE);

  return(fade_token);
}

void DisplayFadeFromBlack(CGDisplayFadeReservationToken fade_token, bool fade)
{
  if (fade_token != kCGDisplayFadeReservationInvalidToken)
  {
    if (fade)
      CGDisplayFade(fade_token, 0.5, kCGDisplayBlendSolidColor, kCGDisplayBlendNormal, 0.0, 0.0, 0.0, FALSE);
    CGReleaseDisplayFadeReservation(fade_token);
  }
}

NSString* screenNameForDisplay(CGDirectDisplayID displayID)
{
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  NSString *screenName = nil;

  NSDictionary *deviceInfo = (NSDictionary *)IODisplayCreateInfoDictionary(CGDisplayIOServicePort(displayID), kIODisplayOnlyPreferredName);
  NSDictionary *localizedNames = [deviceInfo objectForKey:[NSString stringWithUTF8String:kDisplayProductName]];

  if ([localizedNames count] > 0) {
      screenName = [[localizedNames objectForKey:[[localizedNames allKeys] objectAtIndex:0]] retain];
  }

  [deviceInfo release];
  [pool release];

  return [screenName autorelease];
}

/*
void ShowHideNSWindow(NSWindow *wind, bool show)
{
  if (show)
    [wind orderFront:nil];
  else
    [wind orderOut:nil];
}
*/

static NSWindow *curtainWindow;
void fadeInDisplay(NSScreen *theScreen, double fadeTime)
{
  int     fadeSteps     = 100;
  double  fadeInterval  = (fadeTime / (double) fadeSteps);

  if (curtainWindow != nil)
  {
    for (int step = 0; step < fadeSteps; step++)
    {
      double fade = 1.0 - (step * fadeInterval);
      [curtainWindow setAlphaValue:fade];

      NSDate *nextDate = [NSDate dateWithTimeIntervalSinceNow:fadeInterval];
      [[NSRunLoop currentRunLoop] runUntilDate:nextDate];
    }
  }
  [curtainWindow close];
  curtainWindow = nil;

  //Cocoa_ShowMouse();
}

void fadeOutDisplay(NSScreen *theScreen, double fadeTime)
{
  int     fadeSteps     = 100;
  double  fadeInterval  = (fadeTime / (double) fadeSteps);

  Cocoa_HideMouse();

  curtainWindow = [[NSWindow alloc]
    initWithContentRect:[theScreen frame]
    styleMask:NSBorderlessWindowMask
    backing:NSBackingStoreBuffered
    defer:YES
    screen:theScreen];

  [curtainWindow setAlphaValue:0.0];
  [curtainWindow setBackgroundColor:[NSColor blackColor]];
  [curtainWindow setLevel:NSScreenSaverWindowLevel];

  [curtainWindow makeKeyAndOrderFront:nil];
  [curtainWindow setFrame:[curtainWindow
    frameRectForContentRect:[theScreen frame]]
    display:YES
    animate:NO];

  for (int step = 0; step < fadeSteps; step++)
  {
    double fade = step * fadeInterval;
    [curtainWindow setAlphaValue:fade];

    NSDate *nextDate = [NSDate dateWithTimeIntervalSinceNow:fadeInterval];
    [[NSRunLoop currentRunLoop] runUntilDate:nextDate];
  }
}

// try to find mode that matches the desired size, refreshrate
// non interlaced, nonstretched, safe for hardware
CFDictionaryRef GetMode(int width, int height, double refreshrate, int screenIdx)
{
  if (screenIdx >= (signed)[[NSScreen screens] count])
    return NULL;

  Boolean stretched;
  Boolean interlaced;
  Boolean safeForHardware;
  Boolean televisionoutput;
  int w, h, bitsperpixel;
  double rate;
  RESOLUTION_INFO res;

  CLog::Log(LOGDEBUG, "GetMode looking for suitable mode with %d x %d @ %f Hz on display %d\n", width, height, refreshrate, screenIdx);

  CFArrayRef displayModes = CGDisplayAvailableModes(GetDisplayID(screenIdx));

  if (NULL == displayModes)
  {
    CLog::Log(LOGERROR, "GetMode - no displaymodes found!");
    return NULL;
  }

  for (int i=0; i < CFArrayGetCount(displayModes); ++i)
  {
    CFDictionaryRef displayMode = (CFDictionaryRef)CFArrayGetValueAtIndex(displayModes, i);

    stretched = GetDictionaryBoolean(displayMode, kCGDisplayModeIsStretched);
    interlaced = GetDictionaryBoolean(displayMode, kCGDisplayModeIsInterlaced);
    bitsperpixel = GetDictionaryInt(displayMode, kCGDisplayBitsPerPixel);
    safeForHardware = GetDictionaryBoolean(displayMode, kCGDisplayModeIsSafeForHardware);
    televisionoutput = GetDictionaryBoolean(displayMode, kCGDisplayModeIsTelevisionOutput);
    w = GetDictionaryInt(displayMode, kCGDisplayWidth);
    h = GetDictionaryInt(displayMode, kCGDisplayHeight);
    rate = GetDictionaryDouble(displayMode, kCGDisplayRefreshRate);


    if ((bitsperpixel == 32)      &&
        (safeForHardware == YES)  &&
        (stretched == NO)         &&
        (interlaced == NO)        &&
        (w == width)              &&
        (h == height)             &&
        (rate == refreshrate || rate == 0))
    {
      CLog::Log(LOGDEBUG, "GetMode found a match!");
      return displayMode;
    }
  }
  CLog::Log(LOGERROR, "GetMode - no match found!");
  return NULL;
}

//---------------------------------------------------------------------------------
static void DisplayReconfigured(CGDirectDisplayID display,
  CGDisplayChangeSummaryFlags flags, void* userData)
{
  CWinSystemOSX *winsys = (CWinSystemOSX*)userData;
  if (!winsys)
    return;

  CLog::Log(LOGDEBUG, "CWinSystemOSX::DisplayReconfigured with flags %d", flags);

  // we fire the callbacks on start of configuration
  // or when the mode set was finished
  // or when we are called with flags == 0 (which is undocumented but seems to happen
  // on some macs - we treat it as device reset)

  // first check if we need to call OnLostDevice
  if (flags & kCGDisplayBeginConfigurationFlag)
  {
    // pre/post-reconfiguration changes
    RESOLUTION res = g_graphicsContext.GetVideoResolution();
    if (res == RES_INVALID)
      return;

    NSScreen* pScreen = nil;
    unsigned int screenIdx = CDisplaySettings::GetInstance().GetResolutionInfo(res).iScreen;

    if (screenIdx < [[NSScreen screens] count])
      pScreen = [[NSScreen screens] objectAtIndex:screenIdx];

    // kCGDisplayBeginConfigurationFlag is only fired while the screen is still
    // valid
    if (pScreen)
    {
      CGDirectDisplayID xbmc_display = GetDisplayIDFromScreen(pScreen);
      if (xbmc_display == display)
      {
        // we only respond to changes on the display we are running on.
        winsys->AnnounceOnLostDevice();
        winsys->StartLostDeviceTimer();
      }
    }
  }
  else // the else case checks if we need to call OnResetDevice
  {
    // we fire if kCGDisplaySetModeFlag is set or if flags == 0
    // (which is undocumented but seems to happen
    // on some macs - we treat it as device reset)
    // we also don't check the screen here as we might not even have
    // one anymore (e.x. when tv is turned off)
    if (flags & kCGDisplaySetModeFlag || flags == 0)
    {
      winsys->StopLostDeviceTimer(); // no need to timeout - we've got the callback
      winsys->AnnounceOnResetDevice();
    }
  }
}

//---------------------------------------------------------------------------------
//---------------------------------------------------------------------------------
CWinSystemOSX::CWinSystemOSX() : CWinSystemBase(), m_lostDeviceTimer(this)
{
  m_eWindowSystem = WINDOW_SYSTEM_OSX;
  m_obscured   = false;
  m_appWindow  = NULL;
  m_glView     = NULL;
  m_obscured_timecheck = XbmcThreads::SystemClockMillis() + 1000;
  m_use_system_screensaver = true;
  // check runtime, we only allow this on 10.5+
  m_can_display_switch = (floor(NSAppKitVersionNumber) >= 949);
  m_lastDisplayNr = -1;
  m_movedToOtherScreen = false;
  m_refreshRate = 0.0;
  m_fullscreenWillToggle = false;
}

CWinSystemOSX::~CWinSystemOSX()
{
}

void CWinSystemOSX::StartLostDeviceTimer()
{
  if (m_lostDeviceTimer.IsRunning())
    m_lostDeviceTimer.Restart();
  else
    m_lostDeviceTimer.Start(LOST_DEVICE_TIMEOUT_MS, false);
}

void CWinSystemOSX::StopLostDeviceTimer()
{
  m_lostDeviceTimer.Stop();
}

void CWinSystemOSX::OnTimeout()
{
  AnnounceOnResetDevice();
}

bool CWinSystemOSX::InitWindowSystem()
{
  if (!CWinSystemBase::InitWindowSystem())
    return false;

  if (m_can_display_switch)
    CGDisplayRegisterReconfigurationCallback(DisplayReconfigured, (void*)this);

  return true;
}

bool CWinSystemOSX::DestroyWindowSystem()
{
  //printf("CWinSystemOSX::DestroyWindowSystem\n");
  if (m_can_display_switch)
    CGDisplayRemoveReconfigurationCallback(DisplayReconfigured, (void*)this);

  DestroyWindowInternal();
  
  if (m_glView)
  {
    // normally, this should happen here but we are racing internal object destructors
    // that make GL calls. They crash if the GLView is released.
    //[(OSXGLView*)m_glView release];
    m_glView = NULL;
  }

  UnblankDisplays();
  
  return true;
}

bool CWinSystemOSX::CreateNewWindow(const std::string& name, bool fullScreen, RESOLUTION_INFO& res, PHANDLE_EVENT_FUNC userFunction)
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  // force initial window creation to be windowed, if fullscreen, it will switch to it below
  // fixes the white screen of death if starting fullscreen and switching to windowed.
  RESOLUTION_INFO resInfo = CDisplaySettings::GetInstance().GetResolutionInfo(RES_WINDOW);
  m_nWidth  = resInfo.iWidth;
  m_nHeight = resInfo.iHeight;
  m_bFullScreen = false;
  m_name        = name;

  // for native fullscreen we always want to set the
  // same windowed flags
  NSUInteger windowStyleMask;
  if (fullScreen && !CDarwinUtils::DeviceHasNativeFullscreen())
    windowStyleMask = NSBorderlessWindowMask;
  else
    windowStyleMask = NSTitledWindowMask|NSResizableWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask;
  
  if (m_appWindow == NULL || !CDarwinUtils::DeviceHasNativeFullscreen())
  {
    NSWindow *appWindow = [[OSXGLWindow alloc] initWithContentRect:NSMakeRect(0, 0, m_nWidth, m_nHeight) styleMask:windowStyleMask];
    appWindow.backgroundColor = [NSColor blackColor];
    NSString *title = [NSString stringWithFormat:@"%s" , m_name.c_str()];
    appWindow.title = title;
    [appWindow makeKeyAndOrderFront:nil];
    [appWindow setOneShot:NO];
    //if (!fullScreen)
    {
      NSWindowCollectionBehavior behavior = [appWindow collectionBehavior];
      behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
      [appWindow setCollectionBehavior:behavior];
    }
    // create new content view
    NSRect rect = [appWindow contentRectForFrameRect:[appWindow frame]];
    
    // create new view if we don't have one
    if(!m_glView)
      m_glView = [[OSXGLView alloc] initWithFrame:rect];
    OSXGLView *contentView = (OSXGLView*)m_glView;
    
    // associate with current window
    [appWindow setContentView: contentView];
    m_bWindowCreated = true;
    
    m_appWindow = appWindow;
  }

  [(NSWindow *)m_appWindow makeKeyWindow];
  
  // check if we have to hide the mouse after creating the window
  // in case we start windowed with the mouse over the window
  // the tracking area mouseenter, mouseexit are not called
  // so we have to decide here to initial hide the os cursor
  NSPoint mouse = [NSEvent mouseLocation];
  if ([NSWindow windowNumberAtPoint:mouse belowWindowWithWindowNumber:0] == ((NSWindow *)m_appWindow).windowNumber)
  {
    Cocoa_HideMouse();
    // warp XBMC cursor to our position
    NSPoint locationInWindowCoords = [(NSWindow *)m_appWindow mouseLocationOutsideOfEventStream];
    XBMC_Event newEvent;
    memset(&newEvent, 0, sizeof(newEvent));
    newEvent.type = XBMC_MOUSEMOTION;
    newEvent.motion.type =  XBMC_MOUSEMOTION;
    newEvent.motion.x =  locationInWindowCoords.x;
    newEvent.motion.y =  locationInWindowCoords.y;
    g_application.OnEvent(newEvent);
  }
  [pool release];

  return true;
}

bool CWinSystemOSX::DestroyWindowInternal()
{
  NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

  if (m_appWindow)
  {
    [(NSWindow *)m_appWindow setContentView:nil];
    [(NSWindow *)m_appWindow release];
    m_appWindow = NULL;
  }

  // get screen refreshrate - this is needed
  // when we startup in windowed mode and don't run through SetFullScreen
  int dummy;
  m_lastDisplayNr = resInfo.iScreen;
  GetScreenResolution(&dummy, &dummy, &m_refreshRate, GetCurrentScreen());
  m_bWindowCreated = false;

  [pool release];
  
  return true;
}

bool CWinSystemOSX::DestroyWindow()
{
  // when using native fullscreen
  // we never destroy the window
  // we reuse it ...
  if (CDarwinUtils::DeviceHasNativeFullscreen())
    return true;

  return DestroyWindowInternal();
}

bool CWinSystemOSX::ResizeWindow(int newWidth, int newHeight, int newLeft, int newTop)
{
  //printf("CWinSystemOSX::ResizeWindow\n");
  if (!m_appWindow)
    return false;
  
  OSXGLView *view = [(NSWindow*)m_appWindow contentView];
  
  if (view && (newWidth > 0) && (newHeight > 0))
  {
    NSOpenGLContext *context = [view getGLContext];
    NSWindow* window = (NSWindow*)m_appWindow;
    
    [window setContentSize:NSMakeSize(newWidth, newHeight)];
    [window update];
    [view setFrameSize:NSMakeSize(newWidth, newHeight)];
    [context update];
  }
  m_nWidth = newWidth;
  m_nHeight = newHeight;

  return true;
}

//static bool needtoshowme = true;

bool CWinSystemOSX::SetFullScreen(bool fullScreen, RESOLUTION_INFO& res, bool blankOtherDisplays)
{
  CSingleLock lock (m_critSection);
  //printf("CWinSystemOSX::SetFullScreen\n");
  static NSPoint last_window_origin;
  static NSSize last_view_size;
  static NSPoint last_view_origin;
  //bool was_fullscreen = m_bFullScreen;
  
  if (m_lastDisplayNr == -1)
    m_lastDisplayNr = res.iScreen;

  NSWindow *window = (NSWindow *)m_appWindow;
  OSXGLView *view = [window contentView];
  
  if (m_lastDisplayNr == -1)
    m_lastDisplayNr = res.iScreen;

  // Fade to black to hide resolution-switching flicker and garbage.
  //CGDisplayFadeReservationToken fade_token = DisplayFadeToBlack(needtoshowme);

  // If we're already fullscreen then we must be moving to a different display.
  // or if we are still on the same display - it might be only a refreshrate/resolution
  // change request.
  // Recurse to reset fullscreen mode and then continue.
  /*
  if (was_fullscreen && fullScreen)
  {
    needtoshowme = false;
    //ShowHideNSWindow([last_view window], needtoshowme);
    RESOLUTION_INFO& window = CDisplaySettings::Get().GetResolutionInfo(RES_WINDOW);
    CWinSystemOSX::SetFullScreen(false, window, blankOtherDisplays);
    needtoshowme = true;
  }
   */

  m_nWidth      = res.iWidth;
  m_nHeight     = res.iHeight;
  m_bFullScreen = fullScreen;
  
  //handle resolution/refreshrate switching early here
  if (m_bFullScreen)
  {
    if (m_can_display_switch)
    {
      // switch videomode
      SwitchToVideoMode(res.iWidth, res.iHeight, res.fRefreshRate, res.iScreen);
      m_lastDisplayNr = res.iScreen;
    }
  }
  
  // we are toggled by osx fullscreen feature
  // only resize and reset the toggle flag
  if (CDarwinUtils::DeviceHasNativeFullscreen() && m_fullscreenWillToggle)
  {
    ResizeWindow(m_nWidth, m_nHeight, -1, -1);
    m_fullscreenWillToggle = false;
    return true;
  }
  
  [window setAllowsConcurrentViewDrawing:NO];

  if (m_bFullScreen)
  {
    // FullScreen Mode
    // Save info about the windowed context so we can restore it when returning to windowed.
    last_view_size = [view frame].size;
    last_view_origin = [view frame].origin;
    last_window_origin = [window  frame].origin;
    
    if (CSettings::GetInstance().GetBool("videoscreen.fakefullscreen"))
    {
      // This is Cocca Windowed FullScreen Mode
      // Get the screen rect of our current display
      NSScreen* pScreen = [[NSScreen screens] objectAtIndex:res.iScreen];
      NSRect    screenRect = [pScreen frame];

      // remove frame origin offset of orginal display
      screenRect.origin = NSZeroPoint;

      DestroyWindow();
      CreateNewWindow(m_name, true, res, NULL);
      window = (NSWindow *)m_appWindow;
      view = [window contentView];
      
      //[window makeKeyAndOrderFront:nil];
      //[window setLevel:NSNormalWindowLevel];
      
      // ...and the original one beneath it and on the same screen.
      //[[view window] setLevel:NSNormalWindowLevel-1];
      
      // old behaviour - set origin to 0,0 when going
      // to fullscreen - not needed when we use native
      // fullscreen mode
      if (!CDarwinUtils::DeviceHasNativeFullscreen())
      {
        [window setFrameOrigin:[pScreen frame].origin];
        [view setFrameOrigin:NSMakePoint(0.0, 0.0)];
      }
      [view setFrameSize:NSMakeSize(m_nWidth, m_nHeight) ];

      NSString *title = [NSString stringWithFormat:@"%s" , ""];
      window.title = title;
      
      if (!CDarwinUtils::DeviceHasNativeFullscreen())
      {
        NSUInteger windowStyleMask = NSBorderlessWindowMask;
        [window setStyleMask:windowStyleMask];
      }
      
      // Hide the menu bar.
      if (GetDisplayID(res.iScreen) == kCGDirectMainDisplay || CDarwinUtils::IsMavericks() )
        SetMenuBarVisible(false);
      
      // Blank other displays if requested.
      if (blankOtherDisplays)
        BlankOtherDisplays(res.iScreen);
    }
    else
    {
      // Capture the display before going fullscreen.
      if (blankOtherDisplays == true)
        CGCaptureAllDisplays();
      else
        CGDisplayCapture(GetDisplayID(res.iScreen));

      // If we don't hide menu bar, it will get events and interrupt the program.
      if (GetDisplayID(res.iScreen) == kCGDirectMainDisplay || CDarwinUtils::IsMavericks() )
        SetMenuBarVisible(false);
    }

    // Hide the mouse.
    Cocoa_HideMouse();
  }
  else
  {
    // Windowed Mode
    // exit fullscreen

    //Cocoa_ShowMouse();

    if (CSettings::GetInstance().GetBool(CSettings::SETTING_VIDEOSCREEN_FAKEFULLSCREEN))
    {
      DestroyWindow();
      CreateNewWindow(m_name, false, res, NULL);
      window = (NSWindow *)m_appWindow;
      view = [window contentView];
      
      //NSString *title = [NSString stringWithFormat:@"%s" , m_name.c_str()];
      //window.title = title;
      //NSUInteger windowStyleMask = NSTitledWindowMask|NSResizableWindowMask|NSClosableWindowMask|NSMiniaturizableWindowMask;
      //[window setStyleMask:windowStyleMask];
      
      // Show menubar.
      if (GetDisplayID(res.iScreen) == kCGDirectMainDisplay || CDarwinUtils::IsMavericks())
        SetMenuBarVisible(true);
      
      // Unblank.
      // Force the unblank when returning from fullscreen, we get called with blankOtherDisplays set false.
      //if (blankOtherDisplays)
        UnblankDisplays();
    }
    else
    {
      // Show menubar.
      if (GetDisplayID(res.iScreen) == kCGDirectMainDisplay || CDarwinUtils::IsMavericks())
        SetMenuBarVisible(true);
      
      // release displays
      CGReleaseAllDisplays();
    }

    // Assign view from old context, move back to original screen.
    [window setFrameOrigin:last_window_origin];
    // return the mouse bounds in view to prevous size
    [view setFrameSize:last_view_size ];
    [view setFrameOrigin:last_view_origin ];
  }

  [window setAllowsConcurrentViewDrawing:YES];

  //DisplayFadeFromBlack(fade_token, needtoshowme);

  //ShowHideNSWindow([last_view window], needtoshowme);

  // set the toggle flag so that the
  // native "willenterfullscreen" et al callbacks
  // know that they are "called" by xbmc and not osx
  if (CDarwinUtils::DeviceHasNativeFullscreen())
  {
    m_fullscreenWillToggle = true;
    // toggle cocoa fullscreen mode
    if ([(NSWindow *)m_appWindow respondsToSelector:@selector(toggleFullScreen:)])
    {
      // does not seem to work, wonder why ?
      //[(NSWindow*)m_appWindow setAnimationBehavior:NSWindowAnimationBehaviorNone];
      [(NSWindow*)m_appWindow toggleFullScreen:nil];
    }
  }
  
  return true;
}

void CWinSystemOSX::UpdateResolutions()
{
  CWinSystemBase::UpdateResolutions();

  // Add desktop resolution
  int w, h;
  double fps;

  // first screen goes into the current desktop mode
  GetScreenResolution(&w, &h, &fps, 0);
  UpdateDesktopResolution(CDisplaySettings::GetInstance().GetResolutionInfo(RES_DESKTOP), 0, w, h, fps);

  // see resolution.h enum RESOLUTION for how the resolutions
  // have to appear in the resolution info vector in CDisplaySettings
  // add the desktop resolutions of the other screens
  for(int i = 1; i < GetNumScreens(); i++)
  {
    RESOLUTION_INFO res;
    // get current resolution of screen i
    GetScreenResolution(&w, &h, &fps, i);
    UpdateDesktopResolution(res, i, w, h, fps);
    CDisplaySettings::GetInstance().AddResolutionInfo(res);
  }

  if (m_can_display_switch)
  {
    // now just fill in the possible reolutions for the attached screens
    // and push to the resolution info vector
    FillInVideoModes();
  }
}

void CWinSystemOSX::GetScreenResolution(int* w, int* h, double* fps, int screenIdx)
{
  // Figure out the screen size. (default to main screen)
  if (screenIdx >= GetNumScreens())
    return;

  CGDirectDisplayID display_id = (CGDirectDisplayID)GetDisplayID(screenIdx);
 
  if (m_appWindow)
    display_id = GetDisplayIDFromScreen( [(NSWindow *)m_appWindow screen] );
  CGDisplayModeRef mode  = CGDisplayCopyDisplayMode(display_id);
  *w = CGDisplayModeGetWidth(mode);
  *h = CGDisplayModeGetHeight(mode);
  *fps = CGDisplayModeGetRefreshRate(mode);
  CGDisplayModeRelease(mode);
  if ((int)*fps == 0)
  {
    // NOTE: The refresh rate will be REPORTED AS 0 for many DVI and notebook displays.
    *fps = 60.0;
  }
}

void CWinSystemOSX::EnableVSync(bool enable)
{
  // OpenGL Flush synchronised with vertical retrace
  GLint swapInterval = enable ? 1 : 0;
  [[NSOpenGLContext currentContext] setValues:&swapInterval forParameter:NSOpenGLCPSwapInterval];
}

bool CWinSystemOSX::SwitchToVideoMode(int width, int height, double refreshrate, int screenIdx)
{
  // SwitchToVideoMode will not return until the display has actually switched over.
  // This can take several seconds.
  if( screenIdx >= GetNumScreens())
    return false;

  boolean_t match = false;
  CFDictionaryRef dispMode = NULL;
  // Figure out the screen size. (default to main screen)
  CGDirectDisplayID display_id = GetDisplayID(screenIdx);

  // find mode that matches the desired size, refreshrate
  // non interlaced, nonstretched, safe for hardware
  dispMode = GetMode(width, height, refreshrate, screenIdx);

  //not found - fallback to bestemdeforparameters
  if (!dispMode)
  {
    dispMode = CGDisplayBestModeForParameters(display_id, 32, width, height, &match);

    if (!match)
      dispMode = CGDisplayBestModeForParameters(display_id, 16, width, height, &match);

    if (!match)
      return false;
  }

  // switch mode and return success
  CGDisplayCapture(display_id);
  CGDisplayConfigRef cfg;
  CGBeginDisplayConfiguration(&cfg);
  // we don't need to do this, we are already faded.
  //CGConfigureDisplayFadeEffect(cfg, 0.3f, 0.5f, 0, 0, 0);
  CGConfigureDisplayMode(cfg, display_id, dispMode);
  CGError err = CGCompleteDisplayConfiguration(cfg, kCGConfigureForAppOnly);
  CGDisplayRelease(display_id);
  
  m_refreshRate = GetDictionaryDouble(dispMode, kCGDisplayRefreshRate);

  Cocoa_CVDisplayLinkUpdate();

  return (err == kCGErrorSuccess);
}

void CWinSystemOSX::FillInVideoModes()
{
  // Add full screen settings for additional monitors
  int numDisplays = [[NSScreen screens] count];

  for (int disp = 0; disp < numDisplays; disp++)
  {
    Boolean stretched;
    Boolean interlaced;
    Boolean safeForHardware;
    Boolean televisionoutput;
    int w, h, bitsperpixel;
    double refreshrate;
    RESOLUTION_INFO res;

    CFArrayRef displayModes = CGDisplayAvailableModes(GetDisplayID(disp));
    NSString *dispName = screenNameForDisplay(GetDisplayID(disp));
    CLog::Log(LOGNOTICE, "Display %i has name %s", disp, [dispName UTF8String]);

    if (NULL == displayModes)
      continue;

    for (int i = 0; i < CFArrayGetCount(displayModes); ++i)
    {
      CFDictionaryRef displayMode = (CFDictionaryRef)CFArrayGetValueAtIndex(displayModes, i);

      stretched = GetDictionaryBoolean(displayMode, kCGDisplayModeIsStretched);
      interlaced = GetDictionaryBoolean(displayMode, kCGDisplayModeIsInterlaced);
      bitsperpixel = GetDictionaryInt(displayMode, kCGDisplayBitsPerPixel);
      safeForHardware = GetDictionaryBoolean(displayMode, kCGDisplayModeIsSafeForHardware);
      televisionoutput = GetDictionaryBoolean(displayMode, kCGDisplayModeIsTelevisionOutput);

      if ((bitsperpixel == 32)      &&
          (safeForHardware == YES)  &&
          (stretched == NO)         &&
          (interlaced == NO))
      {
        w = GetDictionaryInt(displayMode, kCGDisplayWidth);
        h = GetDictionaryInt(displayMode, kCGDisplayHeight);
        refreshrate = GetDictionaryDouble(displayMode, kCGDisplayRefreshRate);
        if ((int)refreshrate == 0)  // LCD display?
        {
          // NOTE: The refresh rate will be REPORTED AS 0 for many DVI and notebook displays.
          refreshrate = 60.0;
        }
        CLog::Log(LOGNOTICE, "Found possible resolution for display %d with %d x %d @ %f Hz\n", disp, w, h, refreshrate);

        UpdateDesktopResolution(res, disp, w, h, refreshrate);

        // overwrite the mode str because  UpdateDesktopResolution adds a
        // "Full Screen". Since the current resolution is there twice
        // this would lead to 2 identical resolution entrys in the guisettings.xml.
        // That would cause problems with saving screen overscan calibration
        // because the wrong entry is picked on load.
        // So we just use UpdateDesktopResolutions for the current DESKTOP_RESOLUTIONS
        // in UpdateResolutions. And on all othere resolutions make a unique
        // mode str by doing it without appending "Full Screen".
        // this is what linux does - though it feels that there shouldn't be
        // the same resolution twice... - thats why i add a FIXME here.
        res.strMode = StringUtils::Format("%dx%d @ %.2f", w, h, refreshrate);
        g_graphicsContext.ResetOverscan(res);
        CDisplaySettings::GetInstance().AddResolutionInfo(res);
      }
    }
  }
}

bool CWinSystemOSX::FlushBuffer(void)
{
  if (m_appWindow)
  {
    OSXGLView *contentView = [(NSWindow *)m_appWindow contentView];
    NSOpenGLContext *glcontex = [contentView getGLContext];
    [glcontex flushBuffer];
  }
  return true;
}

bool CWinSystemOSX::IsObscured(void)
{
  if (m_bFullScreen && !CSettings::GetInstance().GetBool(CSettings::SETTING_VIDEOSCREEN_FAKEFULLSCREEN))
    return false;// in true fullscreen mode - we can't be obscured by anyone...

  // check once a second if we are obscured.
  unsigned int now_time = XbmcThreads::SystemClockMillis();
  if (m_obscured_timecheck > now_time)
    return m_obscured;
  else
    m_obscured_timecheck = now_time + 1000;

  NSOpenGLContext* cur_context = [NSOpenGLContext currentContext];
  NSView* view = [cur_context view];
  if (!view)
  {
    // sanity check, we should always have a view
    m_obscured = true;
    return m_obscured;
  }

  NSWindow *window = [view window];
  if (!window)
  {
    // sanity check, we should always have a window
    m_obscured = true;
    return m_obscured;
  }

  if ([window isVisible] == NO)
  {
    // not visable means the window is not showing.
    // this should never really happen as we are always visable
    // even when minimized in dock.
    m_obscured = true;
    return m_obscured;
  }

  // check if we are minimized (to an icon in the Dock).
  if ([window isMiniaturized] == YES)
  {
    m_obscured = true;
    return m_obscured;
  }

  // check if we are showing on the active workspace.
  if ([window isOnActiveSpace] == NO)
  {
    m_obscured = true;
    return m_obscured;
  }

  // default to false before we start parsing though the windows.
  // if we are are obscured by any windows, then set true.
  m_obscured = false;
  static bool obscureLogged = false;

  CGWindowListOption opts;
  opts = kCGWindowListOptionOnScreenAboveWindow | kCGWindowListExcludeDesktopElements;
  CFArrayRef windowIDs =CGWindowListCreate(opts, (CGWindowID)[window windowNumber]);  

  if (!windowIDs)
    return m_obscured;

  CFArrayRef windowDescs = CGWindowListCreateDescriptionFromArray(windowIDs);
  if (!windowDescs)
  {
    CFRelease(windowIDs);
    return m_obscured;
  }

  CGRect bounds = NSRectToCGRect([window frame]);
  // kCGWindowBounds measures the origin as the top-left corner of the rectangle
  //  relative to the top-left corner of the screen.
  // NSWindow’s frame property measures the origin as the bottom-left corner
  //  of the rectangle relative to the bottom-left corner of the screen.
  // convert bounds from NSWindow to CGWindowBounds here.
  bounds.origin.y = [[window screen] frame].size.height - bounds.origin.y - bounds.size.height;

  std::vector<CRect> partialOverlaps;
  CRect ourBounds = CGRectToCRect(bounds);

  for (CFIndex idx=0; idx < CFArrayGetCount(windowDescs); idx++)
  {
    // walk the window list of windows that are above us and are not desktop elements
    CFDictionaryRef windowDictionary = (CFDictionaryRef)CFArrayGetValueAtIndex(windowDescs, idx);

    // skip the Dock window, it actually covers the entire screen.
    CFStringRef ownerName = (CFStringRef)CFDictionaryGetValue(windowDictionary, kCGWindowOwnerName);
    if (CFStringCompare(ownerName, CFSTR("Dock"), 0) == kCFCompareEqualTo)
      continue;

    // Ignore known brightness tools for dimming the screen. They claim to cover
    // the whole XBMC window and therefore would make the framerate limiter
    // kicking in. Unfortunatly even the alpha of these windows is 1.0 so
    // we have to check the ownerName.
    if (CFStringCompare(ownerName, CFSTR("Shades"), 0)            == kCFCompareEqualTo ||
        CFStringCompare(ownerName, CFSTR("SmartSaver"), 0)        == kCFCompareEqualTo ||
        CFStringCompare(ownerName, CFSTR("Brightness Slider"), 0) == kCFCompareEqualTo ||
        CFStringCompare(ownerName, CFSTR("Displaperture"), 0)     == kCFCompareEqualTo ||
        CFStringCompare(ownerName, CFSTR("Dreamweaver"), 0)       == kCFCompareEqualTo ||
        CFStringCompare(ownerName, CFSTR("Window Server"), 0)     ==  kCFCompareEqualTo)
      continue;

    CFDictionaryRef rectDictionary = (CFDictionaryRef)CFDictionaryGetValue(windowDictionary, kCGWindowBounds);
    if (!rectDictionary)
      continue;

    CGRect windowBounds;
    if (CGRectMakeWithDictionaryRepresentation(rectDictionary, &windowBounds))
    {
      if (CGRectContainsRect(windowBounds, bounds))
      {
        // if the windowBounds completely encloses our bounds, we are obscured.
        if (!obscureLogged)
        {
          std::string appName;
          if (CDarwinUtils::CFStringRefToUTF8String(ownerName, appName))
            CLog::Log(LOGDEBUG, "WinSystemOSX: Fullscreen window %s obscures XBMC!", appName.c_str());
          obscureLogged = true;
        }
        m_obscured = true;
        break;
      }

      // handle overlaping windows above us that combine
      // to obscure by collecting any partial overlaps,
      // then subtract them from our bounds and check
      // for any remaining area.
      CRect intersection = CGRectToCRect(windowBounds);
      intersection.Intersect(ourBounds);
      if (!intersection.IsEmpty())
        partialOverlaps.push_back(intersection);
    }
  }

  if (!m_obscured)
  {
    // if we are here we are not obscured by any fullscreen window - reset flag
    // for allowing the logmessage above to show again if this changes.
    if (obscureLogged)
      obscureLogged = false;
    std::vector<CRect> rects = ourBounds.SubtractRects(partialOverlaps);
    // they got us covered
    if (rects.empty())
      m_obscured = true;
  }

  CFRelease(windowDescs);
  CFRelease(windowIDs);

  return m_obscured;
}

void CWinSystemOSX::NotifyAppFocusChange(bool bGaining)
{
  //printf("CWinSystemOSX::NotifyAppFocusChange\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  if (m_bFullScreen && bGaining)
  {
    // find the window
    NSOpenGLContext* context = [NSOpenGLContext currentContext];
    if (context)
    {
      NSView* view;

      view = [context view];
      if (view)
      {
        NSWindow* window;
        window = [view window];
        if (window)
        {
          // find the screenID
          NSDictionary* screenInfo = [[window screen] deviceDescription];
          NSNumber* screenID = [screenInfo objectForKey:@"NSScreenNumber"];
          if ((CGDirectDisplayID)[screenID longValue] == kCGDirectMainDisplay || CDarwinUtils::IsMavericks() )
          {
            SetMenuBarVisible(false);
          }
          [window orderFront:nil];
        }
      }
    }
  }
  [pool release];
}

void CWinSystemOSX::ShowOSMouse(bool show)
{
  //printf("CWinSystemOSX::ShowOSMouse %d\n", show);
  //SDL_ShowCursor(show ? 1 : 0);
}

bool CWinSystemOSX::Minimize()
{
  //printf("CWinSystemOSX::Minimize\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [[NSApplication sharedApplication] miniaturizeAll:nil];

  [pool release];
  return true;
}

bool CWinSystemOSX::Restore()
{
  //printf("CWinSystemOSX::Restore\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [[NSApplication sharedApplication] unhide:nil];

  [pool release];
  return true;
}

bool CWinSystemOSX::Hide()
{
  //printf("CWinSystemOSX::Hide\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  [[NSApplication sharedApplication] hide:nil];

  [pool release];
  return true;
}

void CWinSystemOSX::HandlePossibleRefreshrateChange()
{
  static double oldRefreshRate = m_refreshRate;
  Cocoa_CVDisplayLinkUpdate();
  int dummy = 0;
  
  GetScreenResolution(&dummy, &dummy, &m_refreshRate, GetCurrentScreen());

  if (oldRefreshRate != m_refreshRate)
  {
    oldRefreshRate = m_refreshRate;
    // send a message so that videoresolution (and refreshrate) is changed
    NSWindow *win = (NSWindow *)m_appWindow;
    NSRect frame = [[win contentView] frame];
    KODI::MESSAGING::CApplicationMessenger::GetInstance().PostMsg(TMSG_VIDEORESIZE, frame.size.width, frame.size.height);
  }
}

void CWinSystemOSX::OnMove(int x, int y)
{
  //printf("CWinSystemOSX::OnMove\n");
}

void CWinSystemOSX::EnableSystemScreenSaver(bool bEnable)
{
  //printf("CWinSystemOSX::EnableSystemScreenSaver\n");
  // see Technical Q&A QA1340
  static IOPMAssertionID assertionID = 0;

  if (!bEnable)
  {
    if (assertionID == 0)
    {
      CFStringRef reasonForActivity= CFSTR("XBMC requested disable system screen saver");
      IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep,
        kIOPMAssertionLevelOn, reasonForActivity, &assertionID);
    }
    UpdateSystemActivity(UsrActivity);
  }
  else if (assertionID != 0)
  {
    IOPMAssertionRelease(assertionID);
    assertionID = 0;
  }

  m_use_system_screensaver = bEnable;
}

bool CWinSystemOSX::IsSystemScreenSaverEnabled()
{
  //printf("CWinSystemOSX::IsSystemScreenSaverEnabled\n");
  return m_use_system_screensaver;
}

void CWinSystemOSX::ResetOSScreensaver()
{
  //printf("CWinSystemOSX::ResetOSScreensaver\n");
  // allow os screensaver only if we are fullscreen
  EnableSystemScreenSaver(!m_bFullScreen);
}

bool CWinSystemOSX::EnableFrameLimiter()
{
  //printf("CWinSystemOSX::EnableFrameLimiter\n");
  return IsObscured();
}

void CWinSystemOSX::EnableTextInput(bool bEnable)
{
  //printf("CWinSystemOSX::EnableTextInput\n");
  if (bEnable)
    StartTextInput();
  else
    StopTextInput();
}

OSXTextInputResponder *g_textInputResponder = nil;
bool CWinSystemOSX::IsTextInputEnabled()
{
  //printf("CWinSystemOSX::IsTextInputEnabled\n");
  return g_textInputResponder != nil && [[g_textInputResponder superview] isEqual: [[NSApp keyWindow] contentView]];
}

void CWinSystemOSX::StartTextInput()
{
  //printf("CWinSystemOSX::StartTextInput\n");
  NSView *parentView = [[NSApp keyWindow] contentView];

  /* We only keep one field editor per process, since only the front most
   * window can receive text input events, so it make no sense to keep more
   * than one copy. When we switched to another window and requesting for
   * text input, simply remove the field editor from its superview then add
   * it to the front most window's content view */
  if (!g_textInputResponder) {
    g_textInputResponder =
    [[OSXTextInputResponder alloc] initWithFrame: NSMakeRect(0.0, 0.0, 0.0, 0.0)];
  }

  if (![[g_textInputResponder superview] isEqual: parentView])
  {
//    DLOG(@"add fieldEdit to window contentView");
    [g_textInputResponder removeFromSuperview];
    [parentView addSubview: g_textInputResponder];
    [[NSApp keyWindow] makeFirstResponder: g_textInputResponder];
  }
}
void CWinSystemOSX::StopTextInput()
{
  //printf("CWinSystemOSX::StopTextInput\n");
  if (g_textInputResponder) {
    [g_textInputResponder removeFromSuperview];
    [g_textInputResponder release];
    g_textInputResponder = nil;
  }
}

void CWinSystemOSX::Register(IDispResource *resource)
{
  //printf("CWinSystemOSX::Register\n");
  CSingleLock lock(m_resourceSection);
  m_resources.push_back(resource);
}

void CWinSystemOSX::Unregister(IDispResource* resource)
{
  //printf("CWinSystemOSX::Unregister\n");
  CSingleLock lock(m_resourceSection);
  std::vector<IDispResource*>::iterator i = find(m_resources.begin(), m_resources.end(), resource);
  if (i != m_resources.end())
    m_resources.erase(i);
}

bool CWinSystemOSX::Show(bool raise)
{
  //printf("CWinSystemOSX::Show\n");
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];

  if (raise)
  {
    [[NSApplication sharedApplication] unhide:nil];
    [[NSApplication sharedApplication] activateIgnoringOtherApps: YES];
    [[NSApplication sharedApplication] arrangeInFront:nil];
  }
  else
  {
    [[NSApplication sharedApplication] unhideWithoutActivation];
  }

  [pool release];
  return true;
}

int CWinSystemOSX::GetNumScreens()
{
  int numDisplays = [[NSScreen screens] count];
  return(numDisplays);
}

int CWinSystemOSX::GetCurrentScreen()
{
  
  // if user hasn't moved us in windowed mode - return the
  // last display we were fullscreened at
  if (!m_movedToOtherScreen)
    return m_lastDisplayNr;

  if (m_appWindow)
  {
    m_movedToOtherScreen = false;
    return GetDisplayIndex(GetDisplayIDFromScreen( [(NSWindow *)m_appWindow screen]));
  }
  return 0;
}

int CWinSystemOSX::CheckDisplayChanging(u_int32_t flags)
{
  NSOpenGLContext* context = [NSOpenGLContext currentContext];
  
  // if user hasn't moved us in windowed mode - return the
  // last display we were fullscreened at
  if (!m_movedToOtherScreen)
    return m_lastDisplayNr;
  
  // if we are here the user dragged the window to a different
  // screen and we return the screen of the window
  if (context)
  {
    NSView* view;

    view = [context view];
    if (view)
    {
      NSWindow* window;
      window = [view window];
      if (window)
      {
        m_movedToOtherScreen = false;
        return GetDisplayIndex(GetDisplayIDFromScreen( [window screen] ));
      }
        
    }
  }
  return 0;
}

void CWinSystemOSX::WindowChangedScreen()
{
  // user has moved the window to a
  // different screen
  m_movedToOtherScreen = true;
  Cocoa_CVDisplayLinkUpdate();
  HandlePossibleRefreshrateChange();
}

void CWinSystemOSX::AnnounceOnLostDevice()
{
  CSingleLock lock(m_resourceSection);
  // tell any shared resources
  CLog::Log(LOGDEBUG, "CWinSystemOSX::AnnounceOnLostDevice");
  for (std::vector<IDispResource *>::iterator i = m_resources.begin(); i != m_resources.end(); i++)
    (*i)->OnLostDisplay();
}

void CWinSystemOSX::AnnounceOnResetDevice()
{
  CSingleLock lock(m_resourceSection);
  // tell any shared resources
  CLog::Log(LOGDEBUG, "CWinSystemOSX::AnnounceOnResetDevice");
  for (std::vector<IDispResource *>::iterator i = m_resources.begin(); i != m_resources.end(); i++)
    (*i)->OnResetDisplay();
}

CGLContextObj CWinSystemOSX::GetCGLContextObj()
{
  CGLContextObj cglcontex = NULL;
  if(m_appWindow)
  {
    OSXGLView *contentView = [(NSWindow*)m_appWindow contentView];
    cglcontex = [[contentView getGLContext] CGLContextObj];
  }

  return cglcontex;
}

std::string CWinSystemOSX::GetClipboardText(void)
{
  std::string utf8_text;

  const char *szStr = Cocoa_Paste();
  if (szStr)
    utf8_text = szStr;

  return utf8_text;
}

float CWinSystemOSX::CocoaToNativeFlip(float y)
{
  // OpenGL specifies that the default origin is at bottom-left.
  // Cocoa specifies that the default origin is at bottom-left.
  // Direct3D specifies that the default origin is at top-left.
  // SDL specifies that the default origin is at top-left.
  // WTF ?

  // TODO hook height and width up to resize events of window and cache them as member
  if (m_appWindow)
  {
    NSWindow *win = (NSWindow *)m_appWindow;
    NSRect frame = [[win contentView] frame];
    y = frame.size.height - y;
  }
  return y;
}

#endif
