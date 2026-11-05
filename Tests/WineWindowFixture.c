#ifndef UNICODE
#define UNICODE
#endif
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
static LRESULT CALLBACK proc(HWND w,UINT m,WPARAM a,LPARAM b){return DefWindowProcW(w,m,a,b);}
static void pump(DWORD duration){ULONGLONG end=GetTickCount64()+duration;MSG m;while(GetTickCount64()<end){while(PeekMessageW(&m,NULL,0,0,PM_REMOVE)){TranslateMessage(&m);DispatchMessageW(&m);}Sleep(10);}}
int wmain(int argc,wchar_t **argv){
 SetProcessDPIAware();
 if((argc!=3 && argc!=4) || wcscmp(argv[1],L"日本語 spaced argument") || wcscmp(argv[2],L"quote\"slash\\"))return 21;
 WNDCLASSW c={0};c.lpfnWndProc=proc;c.hInstance=GetModuleHandleW(NULL);c.lpszClassName=L"GameShelfSyntheticWindow";RegisterClassW(&c);
 HWND w=CreateWindowW(c.lpszClassName,L"GameShelf synthetic window — no game",WS_OVERLAPPEDWINDOW,0,40,640,480,NULL,NULL,c.hInstance,NULL);
 if(!w)return 22;
 int special=argc==4;
 if(special && !wcscmp(argv[3],L"fullscreen")) {
  MONITORINFO m={0};m.cbSize=sizeof(m);GetMonitorInfoW(MonitorFromWindow(w,MONITOR_DEFAULTTOPRIMARY),&m);
  SetWindowLongPtrW(w,GWL_STYLE,WS_POPUP);
  SetWindowPos(w,NULL,m.rcMonitor.left,m.rcMonitor.top,m.rcMonitor.right-m.rcMonitor.left,m.rcMonitor.bottom-m.rcMonitor.top,SWP_NOZORDER|SWP_FRAMECHANGED);
 }
 ShowWindow(w,special && !wcscmp(argv[3],L"maximized")?SW_SHOWMAXIMIZED:SW_SHOWNOACTIVATE);
 pump(150);RECT initial;GetWindowRect(w,&initial);pump(2350);
 if(special){RECT after;GetWindowRect(w,&after);int ok=EqualRect(&initial,&after);
  wchar_t receipt[2048];DWORD length=GetEnvironmentVariableW(L"GAMESHELF_SYNTHETIC_RECEIPT",receipt,2048);
  if(length>0 && length<2048){HANDLE f=CreateFileW(receipt,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);if(f!=INVALID_HANDLE_VALUE){DWORD written;char result=ok?'1':'0';WriteFile(f,&result,1,&written,NULL);CloseHandle(f);}}
  DestroyWindow(w);puts(ok?"PASS synthetic special window unchanged":"FAIL special window moved");return ok?0:25;}
 RECT r;GetWindowRect(w,&r);MONITORINFO mi={0};mi.cbSize=sizeof(mi);GetMonitorInfoW(MonitorFromWindow(w,MONITOR_DEFAULTTONEAREST),&mi);
 int x=mi.rcWork.left+((mi.rcWork.right-mi.rcWork.left)-(r.right-r.left))/2;
 int y=mi.rcWork.top+((mi.rcWork.bottom-mi.rcWork.top)-(r.bottom-r.top))/2;
 if(abs(r.left-x)>2 || abs(r.top-y)>2){fprintf(stderr,"FAIL center actual=%ld,%ld expected=%d,%d\n",r.left,r.top,x,y);DestroyWindow(w);return 23;}
 SetWindowPos(w,NULL,80,100,0,0,SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE);pump(1500);GetWindowRect(w,&r);
 if(abs(r.left-80)>2 || abs(r.top-100)>2){DestroyWindow(w);return 24;}
 DestroyWindow(w);puts("PASS synthetic Win32 center once, later move preserved, Unicode/quote argv round trip");return 0;
}
