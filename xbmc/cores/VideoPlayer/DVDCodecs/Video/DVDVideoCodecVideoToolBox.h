#pragma once
/*
 *      Copyright (C) 2010-2013 Team XBMC
 *      http://xbmc.org
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
 *  along with XBMC; see the file COPYING.  If not, see
 *  <http://www.gnu.org/licenses/>.
 *
 */
#define HAVE_VIDEOTOOLBOXDECODER
#if defined(HAVE_VIDEOTOOLBOXDECODER)
#include <atomic>
#include <queue>

#include "DVDVideoCodec.h"
#include "DVDStreamInfo.h"
#include "DVDCodecs/DVDCodecs.h"
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <VideoToolBox/VideoToolBox.h>

class DllVideoToolBox;
class CBitstreamParser;
class CBitstreamConverter;
struct VTDumpDecompressionPropCtx;

// tracks a frame in and output queue in display order
typedef struct frame_queue {
  double              dts;
  double              pts;
  size_t              width;
  size_t              height;
  int64_t             sort_time;
  FourCharCode        pixel_buffer_format;
  CVPixelBufferRef    pixel_buffer_ref;
  struct frame_queue  *nextframe;
} frame_queue;

class CDVDVideoCodecVideoToolBox : public CDVDVideoCodec
{
public:
  CDVDVideoCodecVideoToolBox(CProcessInfo &processInfo);
  virtual ~CDVDVideoCodecVideoToolBox();
  
  // Required overrides
  virtual bool Open(CDVDStreamInfo &hints, CDVDCodecOptions &options);
  virtual void Dispose(void);
  virtual int  Decode(uint8_t *pData, int iSize, double dts, double pts);
  virtual void Reset(void);
  virtual bool GetPicture(DVDVideoPicture *pDvdVideoPicture);
  virtual bool ClearPicture(DVDVideoPicture* pDvdVideoPicture);
  virtual void SetDropState(bool bDrop);
  virtual const char* GetName(void) { return (const char*)m_pFormatName; }
  virtual unsigned GetConvergeCount();
  virtual unsigned GetAllowedReferences();
  virtual void SetCodecControl(int flags);
  virtual void Reopen();
  
protected:
  void DisplayQueuePop(void);
  void CreateVTSession(int width, int height, CMFormatDescriptionRef fmt_desc);
  void DestroyVTSession(void);
  static void VTDecoderCallback(
                                void *refcon, void *frameInfo,
                                OSStatus status, UInt32 infoFlags, CVBufferRef imageBuffer, CMTime pts, CMTime duration);
  
  CDVDStreamInfo     m_hintsForReopen;
  CDVDCodecOptions   m_optionsForReopen;
  void              *m_vt_session;    // opaque videotoolbox session
  CBitstreamConverter    *m_bitstream;
  CMFormatDescriptionRef  m_fmt_desc;
  
  const char        *m_pFormatName;
  bool              m_DropPictures;
  int               m_codecControlFlags;
  DVDVideoPicture   m_videobuffer;
  
  double            m_sort_time;
  pthread_mutex_t   m_queue_mutex;    // mutex protecting queue manipulation
  frame_queue       *m_display_queue; // display-order queue - next display frame is always at the queue head
  std::atomic<int>  m_queue_depth;    // we will try to keep the queue depth at m_max_ref_frames
  int32_t           m_max_ref_frames;
  bool              m_started;
  int               m_lastKeyframe;
  bool              m_sessionRestart;
  double            m_sessionRestartDTS;
  double            m_sessionRestartPTS;
  bool              m_enable_temporal_processing;
};
#endif