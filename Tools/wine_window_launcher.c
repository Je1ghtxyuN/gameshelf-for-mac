/* Build from source with Zig cc -target x86_64-windows-gnu -municode -Wl,--subsystem,windows -luser32 -lshell32.
 * No hooks, DLL injection, registry writes, cursor changes or macOS AX calls.
 * Launches exactly one child; only its PID's normal top-level window is eligible.
 */
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <shellapi.h>
#include <wchar.h>
#include <stdlib.h>
#include "wine_window_geometry.h"
struct search { DWORD pid; HWND window; };
static BOOL CALLBACK find_window(HWND w,LPARAM p) {
 struct search *s=(struct search *)p; DWORD pid=0; GetWindowThreadProcessId(w,&pid);
 if(pid==s->pid && IsWindowVisible(w) && !GetWindow(w,GW_OWNER) && !(GetWindowLongPtrW(w,GWL_EXSTYLE)&WS_EX_TOOLWINDOW)) {
  RECT r; if(GetWindowRect(w,&r) && r.right-r.left>=320 && r.bottom-r.top>=200) {s->window=w;return FALSE;}
 } return TRUE;
}
/* Inverse of CommandLineToArgvW/MS CRT quoting; never invoke cmd.exe. */
static wchar_t *command(int argc,wchar_t **argv) {
 size_t capacity=1; for(int i=1;i<argc;i++) {size_t n=wcslen(argv[i]); if(n>32767 || capacity+2*n+4>32767)return NULL;capacity+=2*n+4;}
 wchar_t *result=calloc(capacity,sizeof(wchar_t)),*p=result; if(!result)return NULL;
 for(int i=1;i<argc;i++) {
  if(i>1)*p++=L' '; *p++=L'"';size_t slashes=0;
  for(const wchar_t *q=argv[i];;q++) {
   if(*q==L'\\'){slashes++;continue;}
   size_t count=slashes*((!*q || *q==L'"')?2:1);while(count--)*p++=L'\\';slashes=0;
   if(!*q)break;if(*q==L'"')*p++=L'\\';*p++=*q;
  } *p++=L'"';
 } *p=0;return result;
}
static int launch(int argc,wchar_t **argv) {
 if(argc<2)return 64;
 /* Match Wine's own winepath: translate Unix entry paths using its exported
  * mapper instead of assuming Z: or changing the game's working directory. */
 wchar_t *mapped=NULL;
 if(argv[1][0]==L'/') {
  typedef WCHAR * (__cdecl *mapper)(const char *);
  mapper convert=(mapper)(void *)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"wine_get_dos_file_name");
  int bytes=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,argv[1],-1,NULL,0,NULL,NULL);
  if(!convert || bytes<=0)return 64;
  char *unix_name=malloc(bytes);if(!unix_name)return 64;
  WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,argv[1],-1,unix_name,bytes,NULL,NULL);
  mapped=convert(unix_name);free(unix_name);if(!mapped)return 64;argv[1]=mapped;
 }
 wchar_t *line=command(argc,argv);if(!line){if(mapped)HeapFree(GetProcessHeap(),0,mapped);return 64;}
 STARTUPINFOW si={0};PROCESS_INFORMATION pi={0};si.cb=sizeof(si);
 if(!CreateProcessW(argv[1],line,NULL,NULL,FALSE,0,NULL,NULL,&si,&pi)){free(line);if(mapped)HeapFree(GetProcessHeap(),0,mapped);return 65;}
 free(line);if(mapped)HeapFree(GetProcessHeap(),0,mapped);CloseHandle(pi.hThread);
 SetProcessDPIAware();
 wchar_t desktop[256];DWORD needed;
 BOOL normal=GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,desktop,sizeof(desktop),&needed) && !_wcsicmp(desktop,L"Default");
 ULONGLONG deadline=GetTickCount64()+30000; HWND previous=NULL;RECT prior={0};int stable=0;
 while(normal && GetTickCount64()<deadline && WaitForSingleObject(pi.hProcess,100)==WAIT_TIMEOUT) {
  struct search s={pi.dwProcessId,NULL};EnumWindows(find_window,(LPARAM)&s);if(!s.window){stable=0;continue;}
  RECT r; if(!GetWindowRect(s.window,&r))continue;
  if(s.window==previous && EqualRect(&r,&prior))stable++;else stable=0;
  previous=s.window;prior=r;if(stable<3)continue;
  MONITORINFO mi={0};mi.cbSize=sizeof(mi);HMONITOR monitor=MonitorFromWindow(s.window,MONITOR_DEFAULTTONEAREST);
  if(GetMonitorInfoW(monitor,&mi)) {
   BOOL full=r.left<=mi.rcMonitor.left && r.top<=mi.rcMonitor.top && r.right>=mi.rcMonitor.right && r.bottom>=mi.rcMonitor.bottom;
   int x,y;if(gs_center(r.left,r.top,r.right-r.left,r.bottom-r.top,mi.rcWork.left,mi.rcWork.top,mi.rcWork.right,mi.rcWork.bottom,full||IsZoomed(s.window)||IsIconic(s.window),&x,&y))
    SetWindowPos(s.window,NULL,x,y,0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_ASYNCWINDOWPOS);
  } break; /* At most one attempt; never pull back later user movement. */
 }
 WaitForSingleObject(pi.hProcess,INFINITE);DWORD code=1;GetExitCodeProcess(pi.hProcess,&code);CloseHandle(pi.hProcess);return (int)code;
}

/* GUI subsystem: no auxiliary Wine console window during normal launches. */
int WINAPI wWinMain(HINSTANCE instance,HINSTANCE previous,LPWSTR command_line,int show) {
 (void)instance;(void)previous;(void)command_line;(void)show;
 int argc=0;wchar_t **argv=CommandLineToArgvW(GetCommandLineW(),&argc);
 if(!argv)return 64;int result=launch(argc,argv);LocalFree(argv);return result;
}
