#ifndef GAMESHELF_WINDOW_GEOMETRY_H
#define GAMESHELF_WINDOW_GEOMETRY_H
#include <stdint.h>
/* Win32 screen coordinates, not Cocoa points. Oversized/fullscreen windows stay put. */
static int gs_center(int left,int top,int width,int height,int wl,int wt,int wr,int wb,int special,int *x,int *y) {
 (void)left;(void)top;
 int64_t aw=(int64_t)wr-wl,ah=(int64_t)wb-wt;
 if(special || width<320 || height<200 || width>=aw || height>=ah) return 0;
 *x=(int)((int64_t)wl+(aw-width)/2); *y=(int)((int64_t)wt+(ah-height)/2); return 1;
}
#endif
