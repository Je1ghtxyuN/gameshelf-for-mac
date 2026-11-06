#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <string.h>
int wmain(int argc, wchar_t **argv) {
    if (argc != 3 || wcscmp(argv[1], L"日本語 spaced argument") ||
        wcscmp(argv[2], L"quote\"slash\\")) return 21;
    wchar_t module[2048];
    if (!GetModuleFileNameW(NULL, module, 2048) || !wcsstr(module, L"合成 ")) return 22;
    const char *bits = sizeof(void *) == 8 ? "PASS synthetic Windows 64\n" : "PASS synthetic Windows 32\n";
    HANDLE f = CreateFileW(sizeof(void *) == 8 ? L"C:\\smoke64.txt" : L"C:\\smoke32.txt",
                          GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE) return 23;
    DWORD written;
    BOOL ok = WriteFile(f, bits, (DWORD)strlen(bits), &written, NULL);
    CloseHandle(f);
    if (!ok || written != strlen(bits)) return 24;
    fputs(bits, stdout);
    return 0;
}
