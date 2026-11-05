#include <assert.h>
#include "../Tools/wine_window_geometry.h"
int main(void) {
 int x=999,y=999;
 assert(gs_center(0,0,1280,720,0,0,1920,1080,0,&x,&y)); assert(x==320 && y==180);
 assert(gs_center(-1800,50,800,600,-1920,24,0,1080,0,&x,&y)); assert(x==-1360 && y==252);
 assert(!gs_center(0,0,1920,1080,0,0,1920,1080,0,&x,&y));
 assert(!gs_center(0,0,1280,720,0,0,1920,1080,1,&x,&y));
 assert(!gs_center(0,0,2000,1200,0,0,1920,1080,0,&x,&y));
 assert(!gs_center(0,0,0,100,0,0,1920,1080,0,&x,&y));
 return 0;
}
